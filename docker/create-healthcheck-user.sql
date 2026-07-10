-- Cria (ou sincroniza a senha de) o login usado pelo healthcheck do container.
-- Executado via sqlcmd com variáveis -v HealthcheckUser / HealthcheckPassword.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$(HealthcheckUser)')
BEGIN
    CREATE LOGIN [$(HealthcheckUser)] WITH PASSWORD = N'$(HealthcheckPassword)', CHECK_POLICY = OFF;
    PRINT 'Login $(HealthcheckUser) criado.';
END
ELSE
BEGIN
    -- Mantém a senha em dia caso HEALTHCHECK_PASSWORD tenha sido rotacionada no .env.
    ALTER LOGIN [$(HealthcheckUser)] WITH PASSWORD = N'$(HealthcheckPassword)';
    PRINT 'Login $(HealthcheckUser) já existia, senha sincronizada.';
END

GRANT CONNECT SQL TO [$(HealthcheckUser)];
