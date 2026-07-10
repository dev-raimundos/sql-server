#!/bin/bash
# Entrypoint customizado: sobe o sqlservr normalmente e, em paralelo, dispara a
# criação do usuário de healthcheck. Sem isso o healthcheck do compose.yaml falha
# sempre no primeiro start, porque o usuário só pode ser criado com o banco já no ar.
set -e

_term() {
  echo "[entrypoint] recebido SIGTERM, encerrando SQL Server..."
  kill -TERM "$SQLSERVR_PID" 2>/dev/null || true
}
trap _term SIGTERM

/opt/mssql/bin/sqlservr &
SQLSERVR_PID=$!

/usr/config/create-healthcheck-user.sh &

wait "$SQLSERVR_PID"
