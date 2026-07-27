# sp_IndexMaintenance

A SQL Server stored procedure for automated index maintenance across multiple databases on a single instance.

## What It Does

- Evaluates index fragmentation using `sys.dm_db_index_physical_stats`
- Performs **REBUILD** (>50% fragmentation) or **REORGANIZE** (10–50%)
- Updates statistics when `modification_counter` exceeds the dynamic threshold (`SQRT(row_count × 1000)`)
- Tracks maintenance history in `DbMaintenanceLog` — resumes from where it left off if time runs out
- Supports Availability Group awareness, edition detection, and resumable index operations

## Requirements

- SQL Server 2016 or later
- `DBAOps` database (or any DBA operations database — update references accordingly)
- `DbMaintenanceLog` table (script included)

## Key Parameters

| Parameter | Default | Description |
|---|---|---|
| `@DbWhereClause` | `NULL` | Filter databases (e.g. `'LIKE ''AppDB_%'''`) |
| `@TableWhereClause` | `NULL` | Filter tables (e.g. `'IN (''Orders'',''Invoice'')'`) |
| `@MaxDurationMinutes` | `60` | Max runtime per execution |
| `@OnlineRebuild` | `1` | Use ONLINE REBUILD if edition supports it |
| `@MinNumberOfRows` | `50000` | Skip tables with fewer rows |
| `@MinNumberOfPages` | `NULL` | Also include tables exceeding this page count |
| `@Resumable` | `0` | Enable resumable rebuild (Enterprise + SQL 2017+) |

## Basic Usage

```sql
-- Maintain all user databases
EXEC sp_IndexMaintenance;

-- Maintain specific databases and tables
EXEC sp_IndexMaintenance
    @DbWhereClause    = 'LIKE ''AppDB_%''',
    @TableWhereClause = 'IN (''Orders'',''Invoice'')';
```

## Author

Ufuk Gökdemir
