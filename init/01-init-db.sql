-- Edite os valores abaixo antes de executar.
-- Execute via SSMS ou: docker exec -it sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "<SA_PASSWORD>" -i /tmp/01-init-db.sql -C -N d

DECLARE @db   NVARCHAR(128) = N'AppDatabase';
DECLARE @user NVARCHAR(128) = N'appuser';
DECLARE @pwd  NVARCHAR(128) = N'Change_Me_AppUser!';

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @db)
BEGIN
    EXEC(N'CREATE DATABASE [' + @db + ']');
    PRINT 'Banco criado.';
END
GO

USE [AppDatabase];
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'appuser')
BEGIN
    CREATE LOGIN [appuser]
        WITH PASSWORD     = N'Change_Me_AppUser!',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login criado.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'appuser')
BEGIN
    CREATE USER [appuser] FOR LOGIN [appuser];
    ALTER ROLE db_datareader ADD MEMBER [appuser];
    ALTER ROLE db_datawriter ADD MEMBER [appuser];
    GRANT EXECUTE TO [appuser];
    PRINT 'Usuario configurado.';
END
GO
