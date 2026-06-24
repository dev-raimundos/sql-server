FROM mcr.microsoft.com/mssql/server:2022-CU16-ubuntu-22.04

USER root

RUN mkdir -p /data/db /data/log /data/backup /data/dump \
    && chown -R mssql:mssql /data \
    && mkdir -p /docker-entrypoint-initdb.d

COPY --chown=root:root scripts/entrypoint.sh /usr/local/bin/custom-entrypoint.sh
RUN chmod +x /usr/local/bin/custom-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
