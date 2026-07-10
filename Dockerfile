FROM mcr.microsoft.com/mssql/server:2022-CU25-ubuntu-22.04

USER root

COPY docker/entrypoint.sh /usr/config/entrypoint.sh
COPY docker/create-healthcheck-user.sh /usr/config/create-healthcheck-user.sh
COPY docker/create-healthcheck-user.sql /usr/config/create-healthcheck-user.sql

RUN chmod +x /usr/config/entrypoint.sh /usr/config/create-healthcheck-user.sh

USER mssql

ENTRYPOINT ["/usr/config/entrypoint.sh"]
