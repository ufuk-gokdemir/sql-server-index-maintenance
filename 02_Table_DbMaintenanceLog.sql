USE [DBAOps]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Table    : DbMaintenanceLog
-- Purpose  : Tracks index maintenance history per database.
--            Used to resume from where maintenance left off,
--            log duration, last action taken, and errors.
-- Columns  :
--   DBName                       - Database name (PK)
--   LastMaintenanceDate          - Last maintenance completion time
--   LastMaintenanceDurationSeconds - Duration of last maintenance run (seconds)
--   LastMaintenanceAction        - Actions performed: REBUILD, REORGANIZE, STATS_UPDATE (comma-separated)
--                                  NULL if no action was needed
--   LastMaintenancePosition      - Resume position for next run
--   MaintenanceCycle             - Number of completed full maintenance cycles
--   LastErrorMessage             - Error message from last failed run (cleared on success)
--   LastErrorDate                - Timestamp of last error (cleared on success)
-- =============================================

CREATE TABLE [dbo].[DbMaintenanceLog](
    [DBName]                         [sysname]       NOT NULL,
    [LastMaintenanceDate]            [datetime]      NULL,
    [LastMaintenanceDurationSeconds] [int]           NULL,
    [LastMaintenanceAction]          [nvarchar](100) NULL,
    [LastMaintenancePosition]        [int]           NULL,
    [MaintenanceCycle]               [int]           NULL,
    [LastErrorMessage]               [nvarchar](max) NULL,
    [LastErrorDate]                  [datetime]      NULL,
    PRIMARY KEY CLUSTERED ([DBName] ASC)
) ON [PRIMARY]
GO