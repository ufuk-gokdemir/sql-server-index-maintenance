USE [master]
GO

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'DBAOps')
BEGIN
    CREATE DATABASE [DBAOps]
    PRINT 'DBAOps database created.'
END
ELSE
    PRINT 'DBAOps database already exists.'
GO
