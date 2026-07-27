USE [DBAOps]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author             : Ufuk Gökdemir
-- Date created       : 20.08.2025
-- Last modified date : 21.07.2026
-- =============================================

CREATE PROCEDURE [dbo].[sp_IndexMaintenance]
    @CentralScheduleServer  NVARCHAR(128) = NULL
    /*
        Linked server name of the central server that manages maintenance scheduling.
        Bu sunucudaki ServerSlotPlan tablosu sorgulanarak bu sunucuya
        Used to check whether a maintenance slot is assigned to this server.
        If NULL, the slot plan check is skipped and the SP runs in standalone mode,
        starting maintenance directly without central coordination.
    */
   ,@DbWhereClause          NVARCHAR(MAX) = NULL
    /*
        Filters which databases to maintain.
        If NULL, all online user databases are included (system databases excluded).
        Examples:
          'LIKE ''AppDB_%'''
          'IN (''DB1'',''DB2'')'
          'NOT IN (''master'',''tempdb'',''model'',''msdb'')'
    */
   ,@TableWhereClause       NVARCHAR(MAX) = NULL
    /*
        Filters which tables to maintain.
        If NULL, all user tables are included.
        Examples:
          'IN (''TABLE1'',''TABLE2'')'
          'LIKE ''FACT_%'''
          '= ''Orders'''
    */

   ,@IndexScanMode          NVARCHAR(10)  = 'LIMITED'
    /*
        Scan mode for sys.dm_db_index_physical_stats:
          'LIMITED'  - Scans only the leaf level. Fastest mode, sufficient for most scenarios.
          'SAMPLED'  - Samples 1%% of all pages. Medium speed, more accurate fragmentation result.
          'DETAILED' - Scans all index levels. Slowest, most accurate.
                       Can cause significant I/O on large tables — use with caution.
    */

   ,@StatsScanMode          NVARCHAR(20)  = 'FULLSCAN'
    /*
        Scan mode for UPDATE STATISTICS — independent of @IndexScanMode:
          'FULLSCAN'  - Reads all rows, most accurate histogram. Slow on large tables.
          'RESAMPLE'  - Updates using existing sampling rate. Balances speed and accuracy.
          'SAMPLE N PERCENT' or 'SAMPLE N ROWS' — custom sampling rate.
        NOTE: LIMITED, SAMPLED, DETAILED are invalid here; they are specific to index physical stats.
    */

   ,@OnlineRebuild          TINYINT       = 1
    /*
        1 = Checks for Enterprise Edition support first; performs ONLINE REBUILD if supported.
            Falls back to OFFLINE REBUILD automatically on unsupported editions (Standard, etc.).
        0 = Always performs OFFLINE REBUILD without any edition check.
    */

   ,@MaxDOP                 INT           = 1
    /*
        Maximum degree of parallelism for index rebuild/reorganize operations.
        0  = SQL Server decides automatically.
        1  = Single-threaded (recommended — does not impact other workloads).
        N  = Up to N threads are used.
    */

   ,@MinNumberOfPages       INT           = NULL
    /*
        Page count threshold at table level — evaluated with OR logic against @MinNumberOfRows.
        Tables exceeding this page count are included even if row count is below @MinNumberOfRows.
        (10,000 pages ≈ 80 MB)
        If NULL, page count check is disabled — only row count is evaluated.
    */

   ,@MinNumberOfRows        INT           = 50000
    /*
        Row count threshold at table level — evaluated with OR logic against @MinNumberOfPages.
        Tables exceeding this row count are included for maintenance.
        Tables below this threshold are still included if they exceed @MinNumberOfPages.
    */

   ,@MaxDurationMinutes     INT           = 60
    /*
        Maximum total runtime for the SP in minutes.
        When the limit is reached, the current operation completes before the SP exits cleanly.
        If 0 or negative, the loop does not run and maintenance is silently skipped.
        The resume position is saved in DbMaintenanceLog and picked up on the next run.
    */

   ,@LOBCompaction          BIT           = 1
    /*
        Controls LOB (varbinary(max), varchar(max), nvarchar(max), xml) compaction
        during REORGANIZE operations.
        1 = REORGANIZE WITH (LOB_COMPACTION = ON)  — recommended default
        0 = REORGANIZE WITH (LOB_COMPACTION = OFF)
        NOTE: REBUILD already rewrites all data including LOB pages.
             This parameter only affects REORGANIZE operations.
    */

   ,@SortInTempdb           BIT           = 0
    /*
        Controls whether sort operations during REBUILD are performed in tempdb.
        1 = SORT_IN_TEMPDB = ON  — Sort operations are performed in tempdb. If tempdb is on a
            separate disk/filegroup, I/O load is distributed and REBUILD may complete faster.
        0 = SORT_IN_TEMPDB = OFF — Sort operations run in the database where the index resides.
            OFF is recommended when tempdb is not on a separate disk.
        NOTE: Cannot be used together with @Resumable = 1.
    */

   ,@Resumable              BIT           = 0
    /*
        Controls whether the REBUILD operation can be paused and resumed.
        1 = RESUMABLE = ON — Rebuild can be paused (PAUSE) and resumed (RESUME).
            If the maintenance window is insufficient for large indexes, resuming picks up where it left off.
            Requirements:
              - Enterprise or Developer edition only (SQL Server 2017+)
              - ONLINE = ON is required (@OnlineRebuild must be 1)
              - Cannot be combined with @SortInTempdb = 1
        0 = RESUMABLE = OFF (default)
    */

AS
BEGIN
    SET NOCOUNT ON;

    -- Availability Group Check — Per Database
    -- If sys.databases.replica_id IS NULL, the DB is not an AG member — proceed with maintenance.
    -- Also covers Distributed AG and readable secondary scenarios.
    IF EXISTS (
        SELECT 1
        FROM sys.databases d
        INNER JOIN sys.dm_hadr_availability_replica_states ars ON d.replica_id = ars.replica_id
        INNER JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
        WHERE ars.is_local = 1
          AND ars.role_desc <> 'PRIMARY'
          AND d.replica_id IS NOT NULL
    )
    BEGIN
        RAISERROR('This server is an AG SECONDARY replica. Maintenance skipped.', 0, 1) WITH NOWAIT;
        RETURN;
    END

    -- Edition Check for Online Rebuild
    -- EngineEdition = 3 → Enterprise / Developer
    -- EngineEdition = 5 → Azure SQL Database
    -- EngineEdition = 8 → Azure SQL Managed Instance
    DECLARE @OnlineRebuildSupported BIT = 0;
    IF @OnlineRebuild = 1 AND CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (3, 5, 8)
        SET @OnlineRebuildSupported = 1;

    -- RESUMABLE validation
    -- Requirements: Enterprise/Developer (EngineEdition = 3), SQL Server 2017+ (v14), ONLINE = ON
    DECLARE @ResumableSupported BIT = 0;
    IF @Resumable = 1
    BEGIN
        IF CAST(SERVERPROPERTY('EngineEdition') AS INT) <> 3
        BEGIN
            RAISERROR('@Resumable = 1 is only supported on Enterprise or Developer edition. Continuing with RESUMABLE = OFF.', 0, 1) WITH NOWAIT;
            SET @Resumable = 0;
        END
        ELSE IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < 14
        BEGIN
            RAISERROR('@Resumable = 1 requires SQL Server 2017+ (v14). Continuing with RESUMABLE = OFF.', 0, 1) WITH NOWAIT;
            SET @Resumable = 0;
        END
        ELSE IF @OnlineRebuildSupported = 0
        BEGIN
            RAISERROR('@Resumable = 1 requires ONLINE REBUILD (@OnlineRebuild = 1 and Enterprise edition). Continuing with RESUMABLE = OFF.', 0, 1) WITH NOWAIT;
            SET @Resumable = 0;
        END

        IF @Resumable = 1
            SET @ResumableSupported = 1;
    END

    -- RESUMABLE and SORT_IN_TEMPDB conflict check — cannot be used together
    -- @SortInTempdb can be used independently of @Resumable
    IF @ResumableSupported = 1 AND @SortInTempdb = 1
    BEGIN
        RAISERROR('@Resumable = 1 and @SortInTempdb = 1 cannot be used together. Continuing with @SortInTempdb = 0.', 0, 1) WITH NOWAIT;
        SET @SortInTempdb = 0;
    END

    -- Slot check — skipped if @CentralScheduleServer is NULL (standalone mode).
    -- Otherwise, the slot plan is queried via the specified linked server.
    DECLARE @ThisServer  NVARCHAR(128) = @@SERVERNAME;
    DECLARE @CurrentHour VARCHAR(23)   = CONVERT(VARCHAR(23), DATEADD(HOUR, DATEDIFF(HOUR, 0, GETDATE()), 0), 121);

    IF @CentralScheduleServer IS NOT NULL
    BEGIN
        DECLARE @t TABLE (val VARCHAR(50));
        DECLARE @cmd NVARCHAR(MAX);

        SET @cmd = N'SELECT DBServer
                     FROM ' + QUOTENAME(@CentralScheduleServer) + N'.[DBAOps].dbo.ServerSlotPlan
                     WHERE DBServer = @pServer
                       AND SlotTime = @pHour;';

        BEGIN TRY
            INSERT INTO @t
            EXEC sp_executesql @cmd,
                N'@pServer NVARCHAR(128), @pHour VARCHAR(23)',
                @pServer = @ThisServer,
                @pHour   = @CurrentHour;
        END TRY
        BEGIN CATCH
            DECLARE @linkedErrMsg NVARCHAR(MAX) = ERROR_MESSAGE();
            RAISERROR('Cannot connect to central server (%s) — slot plan unavailable. Error: %s',
                      16, 1, @CentralScheduleServer, @linkedErrMsg);
            RETURN;
        END CATCH

        IF NOT EXISTS (SELECT 1 FROM @t)
        BEGIN
            PRINT 'No maintenance slot assigned to this server at this time.';
            RETURN;
        END
    END

    RAISERROR('Maintenance slot assigned to this server — starting...', 0, 1) WITH NOWAIT;

    -- List of databases to maintain
    DECLARE @dbList TABLE (ID INT IDENTITY(1,1), DBName SYSNAME);
    DECLARE @cmd2 NVARCHAR(MAX);

    SET @cmd2 = N'
        SELECT name
        FROM sys.databases
        WHERE state_desc = ''ONLINE''' +
        CASE
            WHEN @DbWhereClause IS NOT NULL
            THEN N' AND name ' + @DbWhereClause
            ELSE N' AND name NOT IN (''master'',''tempdb'',''model'',''msdb'')'
        END + N'
        ORDER BY name;';

    INSERT INTO @dbList
    EXEC sp_executesql @cmd2;

    -- Register new databases in the log table
    DECLARE @maxPos INT = ISNULL((SELECT MAX(LastMaintenancePosition) FROM [DBAOps].dbo.DbMaintenanceLog), 0);

    INSERT INTO [DBAOps].dbo.DbMaintenanceLog (DBName, LastMaintenanceDate, LastMaintenancePosition, MaintenanceCycle)
    SELECT d.DBName, NULL, @maxPos + ROW_NUMBER() OVER (ORDER BY d.DBName), 0
    FROM @dbList d
    WHERE NOT EXISTS (SELECT 1 FROM [DBAOps].dbo.DbMaintenanceLog l WHERE l.DBName = d.DBName);

    -- Resume from last position
    DECLARE @lastPosition INT;
    SELECT @lastPosition = MAX(LastMaintenancePosition)
    FROM [DBAOps].dbo.DbMaintenanceLog;

    IF @lastPosition IS NULL OR @lastPosition >= (SELECT COUNT(*) FROM @dbList)
        SET @lastPosition = 0;

    -- Main loop
    DECLARE @i                INT      = @lastPosition + 1;
    DECLARE @max              INT      = (SELECT COUNT(*) FROM @dbList);
    DECLARE @dbName           SYSNAME;
    DECLARE @sql              NVARCHAR(MAX);
    DECLARE @maintenanceStart DATETIME = GETDATE();
    DECLARE @hasError         BIT      = 0;

    IF @MaxDurationMinutes > 0
    BEGIN
        WHILE @i <= @max
        BEGIN
            IF DATEDIFF(MINUTE, @maintenanceStart, GETDATE()) >= @MaxDurationMinutes
            BEGIN
                RAISERROR('Maintenance time limit of %d minute(s) reached — stopping.', 0, 1, @MaxDurationMinutes) WITH NOWAIT;
                BREAK;
            END

            SELECT @dbName = DBName FROM @dbList WHERE ID = @i;
            DECLARE @dbStart  DATETIME    = GETDATE();
            DECLARE @dbAction NVARCHAR(100) = NULL;

            DROP TABLE IF EXISTS #ActionResult;
            CREATE TABLE #ActionResult (Action NVARCHAR(20) NOT NULL);

            BEGIN TRY
                SET @sql = N'
                USE ' + QUOTENAME(@dbName) + N';

                DROP TABLE IF EXISTS #tmpTables;
                CREATE TABLE #tmpTables (ID INT IDENTITY(1,1), TableName SYSNAME);

                INSERT INTO #tmpTables (TableName)
                SELECT name FROM sys.objects
                WHERE type = ''U''' +
                CASE
                    WHEN @TableWhereClause IS NOT NULL
                    THEN N' AND name ' + @TableWhereClause
                    ELSE N''
                END + N';

                DECLARE @j INT = 1;
                DECLARE @maxTable INT = (SELECT COUNT(*) FROM #tmpTables);
                DECLARE @tbl SYSNAME;

                WHILE @j <= @maxTable
                BEGIN
                    SELECT @tbl = TableName FROM #tmpTables WHERE ID = @j;

                    IF EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(@tbl) AND type = ''U'')
                    BEGIN
                        DECLARE @rowCount  INT;
                        DECLARE @pageCount BIGINT;

                        SELECT @rowCount  = SUM(row_count),
                               @pageCount = SUM(used_page_count)
                        FROM sys.dm_db_partition_stats
                        WHERE object_id = OBJECT_ID(@tbl, ''U'')
                          AND index_id IN (0, 1);

                        IF @rowCount >= ' + CAST(@MinNumberOfRows AS NVARCHAR) + N'
                           OR (' + CASE WHEN @MinNumberOfPages IS NOT NULL THEN '@pageCount >= ' + CAST(@MinNumberOfPages AS NVARCHAR) ELSE '0 = 1' END + N')
                        BEGIN
                            DROP TABLE IF EXISTS #Indexes;

                            SELECT
                                ROW_NUMBER() OVER (ORDER BY i.index_id) AS RowNum,
                                i.name          AS IndexName,
                                i.object_id     AS ObjectID,
                                i.index_id      AS IndexID,
                                s.avg_fragmentation_in_percent AS Fragmentation,
                                s.page_count    AS PageCount
                            INTO #Indexes
                            FROM sys.dm_db_index_physical_stats(
                                     DB_ID(), OBJECT_ID(@tbl), NULL, NULL,
                                     ''' + @IndexScanMode + N'''
                                 ) s
                            JOIN sys.indexes i
                                ON s.object_id = i.object_id
                               AND s.index_id  = i.index_id
                            WHERE s.index_id > 0;

                            DECLARE @row   INT = 1;
                            DECLARE @total INT = (SELECT COUNT(*) FROM #Indexes);

                            WHILE @row <= @total
                            BEGIN
                                DECLARE @indexName    SYSNAME;
                                DECLARE @objID        INT;
                                DECLARE @idxID        INT;
                                DECLARE @frag         FLOAT;
                                DECLARE @indexCmd     NVARCHAR(MAX);
                                DECLARE @actionTaken  NVARCHAR(20) = ''NONE'';

                                SELECT
                                    @indexName = IndexName,
                                    @objID     = ObjectID,
                                    @idxID     = IndexID,
                                    @frag      = Fragmentation
                                FROM #Indexes WHERE RowNum = @row;

                                -- Index maintenance decision:
                                -- > 50%  → REBUILD    (statistics are updated automatically after REBUILD)
                                -- 10-50% → REORGANIZE (statistics not updated — checked below)
                                -- < 10%  → No action

                                IF @frag > 50
                                BEGIN
                                    SET @indexCmd = N''ALTER INDEX ['' + @indexName + ''] ON ['' + @tbl + '']
                                        REBUILD WITH (
                                            ONLINE = ' + CASE WHEN @OnlineRebuildSupported = 1 THEN N'ON (WAIT_AT_LOW_PRIORITY (MAX_DURATION = 5 MINUTES, ABORT_AFTER_WAIT = SELF))' ELSE N'OFF' END + N',
                                            RESUMABLE = ' + CASE WHEN @ResumableSupported = 1 THEN N'ON' ELSE N'OFF' END + N',
                                            SORT_IN_TEMPDB = ' + CASE WHEN @SortInTempdb = 1 THEN N'ON' ELSE N'OFF' END + N',
                                            MAXDOP = ' + CAST(@MaxDOP AS NVARCHAR) + N')'';

                                    EXEC sp_executesql @indexCmd;
                                    SET @actionTaken = ''REBUILD'';
                                    IF NOT EXISTS (SELECT 1 FROM #ActionResult WHERE Action = ''REBUILD'')
                                        INSERT INTO #ActionResult VALUES (''REBUILD'');
                                END
                                ELSE IF @frag >= 10
                                BEGIN
                                    SET @indexCmd = N''ALTER INDEX ['' + @indexName + ''] ON ['' + @tbl + ''] REORGANIZE' +
                                        CASE WHEN @LOBCompaction = 1 THEN N' WITH (LOB_COMPACTION = ON)' ELSE N'' END + N''';
                                    EXEC sp_executesql @indexCmd;
                                    SET @actionTaken = ''REORGANIZE'';
                                    IF NOT EXISTS (SELECT 1 FROM #ActionResult WHERE Action = ''REORGANIZE'')
                                        INSERT INTO #ActionResult VALUES (''REORGANIZE'');
                                END

                                -- Statistics update decision
                                -- After REBUILD, statistics are already updated — skip this block.
                                -- After REORGANIZE or no action, check modification_counter.
                                -- Threshold: SQRT(row_count * 1000) — mirrors SQL Server s dynamic auto-update logic.

                                IF @actionTaken <> ''REBUILD''
                                BEGIN
                                    DECLARE @modCounter   BIGINT;
                                    DECLARE @statRowCount BIGINT;
                                    DECLARE @statsID      INT;

                                    -- stats_id-based match: index_id and stats_id do not always align
                                    SELECT @statsID = stats_id
                                    FROM sys.stats
                                    WHERE object_id = @objID
                                      AND name = @indexName;

                                    IF @statsID IS NOT NULL
                                    BEGIN
                                        SELECT
                                            @modCounter   = modification_counter,
                                            @statRowCount = [rows]
                                        FROM sys.dm_db_stats_properties(@objID, @statsID);

                                        IF ISNULL(@modCounter, 0) > 0
                                           AND ISNULL(@modCounter, 0) >= SQRT(ISNULL(@statRowCount, 0) * 1000.0)
                                        BEGIN
                                            DECLARE @statsCmd NVARCHAR(MAX);
                                            SET @statsCmd = N''UPDATE STATISTICS ['' + @tbl + ''] ['' + @indexName + '']
                                                WITH ' + @StatsScanMode + N', MAXDOP = ' + CAST(@MaxDOP AS NVARCHAR) + N''';
                                            EXEC sp_executesql @statsCmd;
                                            IF NOT EXISTS (SELECT 1 FROM #ActionResult WHERE Action = ''STATS_UPDATE'')
                                                INSERT INTO #ActionResult VALUES (''STATS_UPDATE'');
                                        END
                                    END
                                END

                                SET @row += 1;
                            END -- index loop

                        END -- MinNumberOfRows
                    END -- object_id check
                    SET @j += 1;
                END -- table loop
                ';

                EXEC sp_executesql @sql;

                SELECT @dbAction = STRING_AGG(Action, ', ') 
                FROM #ActionResult;

            END TRY
            BEGIN CATCH
                DECLARE @errMsg NVARCHAR(MAX) = ERROR_MESSAGE();
                DECLARE @errNum INT           = ERROR_NUMBER();
                RAISERROR('ERROR - DB: %s | Msg %d: %s', 0, 1, @dbName, @errNum, @errMsg) WITH NOWAIT;

                SET @hasError = 1;

                UPDATE [DBAOps].dbo.DbMaintenanceLog
                SET LastErrorMessage = @errMsg,
                    LastErrorDate    = GETDATE()
                WHERE DBName = @dbName;
            END CATCH

            IF @hasError = 0
                RAISERROR('Maintenance completed: %s', 0, 1, @dbName) WITH NOWAIT;

            UPDATE [DBAOps].dbo.DbMaintenanceLog
            SET LastMaintenanceDate            = GETDATE(),
                LastMaintenancePosition        = @i,
                LastMaintenanceDurationSeconds = DATEDIFF(SECOND, @dbStart, GETDATE()),
                LastMaintenanceAction          = @dbAction,
                LastErrorMessage               = CASE WHEN @hasError = 0 THEN NULL ELSE LastErrorMessage END,
                LastErrorDate                  = CASE WHEN @hasError = 0 THEN NULL ELSE LastErrorDate END,
                MaintenanceCycle               = ISNULL(MaintenanceCycle, 0) + CASE WHEN @hasError = 0 THEN 1 ELSE 0 END
            WHERE DBName = @dbName;

            SET @hasError = 0;

            SET @i += 1;
        END -- DB loop

        IF @i > @max
        BEGIN
            PRINT 'All databases maintained. Starting new maintenance cycle.';
            UPDATE [DBAOps].dbo.DbMaintenanceLog
            SET LastMaintenancePosition = 0;
        END

    END -- IF @MaxDurationMinutes > 0

END
GO

