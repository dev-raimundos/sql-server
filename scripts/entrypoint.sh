#!/bin/bash
set -eo pipefail

SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
SA_PWD="${MSSQL_SA_PASSWORD:-${SA_PASSWORD}}"
INIT_DIR="/docker-entrypoint-initdb.d"

mkdir -p /data/db /data/log /data/backup /data/dump
chown -R mssql:mssql /data

runuser -u mssql -- /opt/mssql/bin/sqlservr &
SQLSERVER_PID=$!

RETRIES=90
until $SQLCMD -S localhost -U sa -P "$SA_PWD" -Q "SELECT 1" -C -N d -l 5 &>/dev/null; do
    RETRIES=$((RETRIES - 1))
    if [ "$RETRIES" -le 0 ]; then
        echo "[entrypoint] ERRO: SQL Server nao respondeu a tempo." >&2
        kill "$SQLSERVER_PID"
        exit 1
    fi
    sleep 2
done

if [ -d "$INIT_DIR" ]; then
    for f in "$INIT_DIR"/*.sql "$INIT_DIR"/*.sh; do
        [ -f "$f" ] || continue
        case "$f" in
            *.sql)
                $SQLCMD -S localhost -U sa -P "$SA_PWD" -i "$f" -C -N d \
                    -v APP_DB_NAME="${APP_DB_NAME:-AppDatabase}" \
                    -v APP_DB_USER="${APP_DB_USER:-appuser}" \
                    -v APP_DB_PASSWORD="${APP_DB_PASSWORD}"
                ;;
            *.sh)
                bash "$f"
                ;;
        esac
    done
fi

wait "$SQLSERVER_PID"
