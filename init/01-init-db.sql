IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'$(APP_DB_NAME)')
BEGIN
    CREATE DATABASE [$(APP_DB_NAME)]
        ON PRIMARY (
            NAME = N'$(APP_DB_NAME)_data',
            FILENAME = N'/data/db/$(APP_DB_NAME).mdf',
            SIZE = 256MB,
            MAXSIZE = UNLIMITED,
            FILEGROWTH = 64MB
        )
        LOG ON (
            NAME = N'$(APP_DB_NAME)_log',
            FILENAME = N'/data/log/$(APP_DB_NAME).ldf',
            SIZE = 64MB,
            MAXSIZE = 2048MB,
            FILEGROWTH = 64MB
        );
    PRINT 'Banco $(APP_DB_NAME) criado.';
END
GO

USE [$(APP_DB_NAME)];
GO

IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = N'$(APP_DB_USER)')
BEGIN
    CREATE LOGIN [$(APP_DB_USER)]
        WITH PASSWORD   = N'$(APP_DB_PASSWORD)',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login $(APP_DB_USER) criado.';
END
GO

IF NOT EXISTS (SELECT name FROM sys.database_principals WHERE name = N'$(APP_DB_USER)')
BEGIN
    CREATE USER [$(APP_DB_USER)] FOR LOGIN [$(APP_DB_USER)];
    ALTER ROLE db_datareader ADD MEMBER [$(APP_DB_USER)];
    ALTER ROLE db_datawriter ADD MEMBER [$(APP_DB_USER)];
    GRANT EXECUTE TO [$(APP_DB_USER)];
    PRINT 'Usuario $(APP_DB_USER) configurado.';
END
GO
