#!/bin/bash
# Roda em paralelo ao sqlservr no primeiro start (e em todo restart) para garantir
# que o login usado pelo healthcheck do compose.yaml exista antes do healthcheck rodar.
set -eu

SQLCMD=/opt/mssql-tools18/bin/sqlcmd
HEALTHCHECK_USER="${HEALTHCHECK_USER:-healthcheck_user}"

if [ -z "${HEALTHCHECK_PASSWORD:-}" ]; then
  echo "[healthcheck-user] HEALTHCHECK_PASSWORD não definido, pulando criação do usuário." >&2
  exit 0
fi

echo "[healthcheck-user] aguardando SQL Server aceitar conexões..."
ready=0
for _ in $(seq 1 90); do
  if "$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [ "$ready" -ne 1 ]; then
  echo "[healthcheck-user] SQL Server não respondeu a tempo, abortando criação do usuário." >&2
  exit 0
fi

echo "[healthcheck-user] criando/sincronizando login '$HEALTHCHECK_USER'..."
"$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C \
  -v HealthcheckUser="$HEALTHCHECK_USER" HealthcheckPassword="$HEALTHCHECK_PASSWORD" \
  -i /usr/config/create-healthcheck-user.sql

echo "[healthcheck-user] pronto."
