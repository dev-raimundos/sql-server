# SQL Server Developer — Production Stack

> Stack Docker para SQL Server 2022 com versão fixada, limite de 6 GB de RAM e inicialização automatizada do banco da aplicação.

---

## O que é isso

Este repositório contém a configuração completa para subir o **SQL Server 2022 Developer Edition** via Docker Compose em um servidor gerenciado pelo **Coolify**. A stack cria automaticamente o banco de dados e o usuário da aplicação na primeira inicialização, persiste os dados do usuário no diretório `/data` e integra com a rede interna do Coolify para que outros containers (como a aplicação ASP.NET) alcancem o banco pelo hostname `sqlserver`.

---

## Arquitetura

```
Coolify (rede: coolify)
         │
         │  hostname: sqlserver
         │  porta interna: 1433
         ▼
┌─────────────────────────────────────┐
│            sqlserver                │
│                                     │
│   SQL Server 2022 Developer CU16    │
│   limit: 6 GB RAM / 5,6 GB mssql   │
│                                     │
│  /var/opt/mssql  ← system databases │
│  /data/db        ← MDF da aplicação │
│  /data/log       ← LDF da aplicação │
│  /data/backup    ← backups          │
└──────────┬──────────────────────────┘
           │
    ┌──────┴──────────────────────────┐
    │  sqlserver-system (named vol.)  │  ← master, msdb, model, tempdb
    │  ./data          (bind mount)   │  ← arquivos do banco da aplicação
    └─────────────────────────────────┘
```

O container da aplicação ASP.NET, também gerenciado pelo Coolify, alcança o SQL Server pelo hostname `sqlserver` dentro da rede `coolify`. Nenhuma porta é exposta publicamente.

---

## Engenharia das decisões

### Tag de imagem fixa (`2022-CU16-ubuntu-22.04`)

A tag `latest` ou `2022-latest` muda silenciosamente a cada Cumulative Update lançado pela Microsoft. Em produção isso significa que um `docker compose pull` pode trocar a versão do servidor sem aviso, quebrando comportamentos ou exigindo testes de regressão não planejados.

A tag `2022-CU16-ubuntu-22.04` fixa exatamente a versão do SQL Server e a distro base. Para atualizar, a decisão é explícita e controlada — basta mudar a tag no `Dockerfile` e reconstruir.

> Para verificar as tags disponíveis: `docker pull mcr.microsoft.com/mssql/server --list-tags` ou acesse o MCR diretamente.

### Imagem customizada via `Dockerfile`

O SQL Server não tem o equivalente ao `/docker-entrypoint-initdb.d/` do PostgreSQL. A imagem oficial inicia o servidor e para por aí — não há mecanismo nativo para rodar scripts SQL após a primeira inicialização.

O `Dockerfile` adiciona um `entrypoint.sh` que:

1. Garante que os subdiretórios de `/data` existem com as permissões corretas.
2. Inicia o `sqlservr` em background.
3. Aguarda o servidor aceitar conexões (com timeout e retry).
4. Executa todos os arquivos `.sql` e `.sh` de `/docker-entrypoint-initdb.d` em ordem alfabética.
5. Aguarda o processo principal encerrar (evitando que o container morra).

O container ainda roda como o usuário `mssql` (sem privilégios) — o `root` é usado apenas durante o build para criar diretórios e copiar o script.

### Dois volumes separados

O SQL Server mantém dois grupos de arquivos com necessidades distintas:

**`sqlserver-system` (named volume → `/var/opt/mssql`)** armazena os bancos de sistema (`master`, `msdb`, `model`, `tempdb`) e a configuração interna do servidor. É gerenciado pelo Docker e não precisa ser acessível diretamente no host.

**`./data` (bind mount → `/data`)** armazena os arquivos `.mdf` e `.ldf` do banco da aplicação. Sendo um bind mount, os arquivos ficam visíveis e acessíveis na máquina host em `./data/db` e `./data/log` — útil para backups externos, inspeção e migração sem depender do Docker volume CLI.

### Limite de memória duplo

O limite de 6 GB é aplicado em duas camadas:

**Docker** (`deploy.resources.limits.memory: 6g`) — o kernel do Linux mata o container se ele tentar alocar além desse valor. É o teto absoluto.

**SQL Server** (`mssql.conf: memorylimitmb = 5632`) — o próprio servidor é configurado para não alocar mais que 5,5 GB para o buffer pool. Os ~512 MB restantes ficam disponíveis para o SO do container, as threads do próprio SQL Server e o `entrypoint.sh`. Sem esse ajuste, o SQL Server tentaria usar toda a RAM disponível e o Docker OOM Killer encerraria o processo de forma abrupta.

### `mssql.conf` montado como read-only

O arquivo de configuração é montado com `:ro` para que o processo do SQL Server (que roda sem root) não consiga modificá-lo em runtime. Qualquer mudança de configuração passa pelo arquivo no repositório e exige um rebuild intencional.

### Healthcheck com `sqlcmd`

O Coolify (e o Docker em geral) só considera o container "saudável" após o healthcheck passar. O check executa um `SELECT 1` via `sqlcmd` dentro do próprio container. O `start_period: 90s` dá margem para a inicialização completa do SQL Server antes de começar a contar as retries — evitando falsos alarmes e restarts prematuros.

As flags `-C -N d` desativam a verificação de certificado e a criptografia forçada para a conexão local de healthcheck (loopback). Conexões externas continuam sujeitas às regras da rede do Coolify.

### Init SQL idempotente

O script `init/01-init-db.sql` usa `IF NOT EXISTS` em todas as operações. Isso significa que ele pode ser executado múltiplas vezes sem efeitos colaterais — útil se o container for recriado com o volume de sistema preservado.

O usuário da aplicação recebe apenas `db_datareader`, `db_datawriter` e `EXECUTE` — sem acesso a DDL ou a outros bancos. A senha do `sa` fica separada e é usada somente internamente pela stack.

### Rede `coolify` como `external: true`

O Coolify cria e gerencia a rede `coolify` fora do ciclo de vida de qualquer compose individual. Declarar `external: true` informa ao Docker Compose que ele não deve criar, modificar ou destruir essa rede — apenas se juntar a ela. Sem isso, um `docker compose down` tentaria remover a rede do Coolify e derrubaria todos os outros containers conectados.

---

## Estrutura do repositório

```
.
├── compose.yaml                    # definição dos serviços
├── Dockerfile                      # imagem customizada com entrypoint de init
├── .env                            # credenciais (não versionar)
├── .env.example                    # modelo sem valores reais (pode versionar)
├── .gitignore
├── config/
│   └── mssql.conf                  # configuração do SQL Server (memória, paths, rede)
├── scripts/
│   └── entrypoint.sh               # wrapper de inicialização com suporte a init scripts
├── init/
│   └── 01-init-db.sql              # cria banco e usuário da aplicação
└── data/                           # arquivos MDF/LDF gerados em runtime (não versionar)
```

---

## Como usar

**1. Configure as credenciais**

```bash
cp .env.example .env
```

Edite o `.env`:

```env
SA_PASSWORD=Sua_Senha_SA_Forte!
APP_DB_NAME=NomeDoBanco
APP_DB_USER=appuser
APP_DB_PASSWORD=Sua_Senha_App_Forte!
SQL_PORT=1433
TZ=America/Sao_Paulo
```

**2. Suba via Coolify**

Aponte o Coolify para este repositório com tipo **Docker Compose**. O Coolify vai executar `docker compose up` automaticamente.

Ou suba manualmente:

```bash
docker compose up -d --build
```

**3. Acompanhe a inicialização**

```bash
docker compose logs -f sqlserver
```

Na primeira execução você verá o `entrypoint.sh` aguardar o servidor ficar disponível e então executar o `01-init-db.sql`.

**4. Connection string na aplicação ASP.NET**

```
Server=sqlserver,1433;Database=NomeDoBanco;User Id=appuser;Password=...;TrustServerCertificate=True;
```

O hostname `sqlserver` funciona porque ambos os containers estão na rede `coolify` do Coolify.

**5. Backup manual**

```bash
# Dentro do container
docker exec -it sqlserver /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$SA_PASSWORD" -C -N d \
  -Q "BACKUP DATABASE [NomeDoBanco] TO DISK = '/data/backup/NomeDoBanco.bak' WITH FORMAT"
```

---

## Requisitos

- Docker Engine 26+
- Docker Compose v2 (plugin)
- Coolify com a rede `coolify` criada (padrão em qualquer instalação)
- Mínimo de 6 GB de RAM disponível para o container

---

## Notas de segurança

- O arquivo `.env` **nunca** deve ser commitado. O `.gitignore` já o exclui.
- O usuário `appuser` não tem permissões de DDL — não consegue criar ou dropar tabelas. Migrações devem ser executadas com o usuário `sa` ou com um usuário específico para deploy.
- A porta `1433` não é exposta publicamente. O SQL Server só é acessível por containers na rede `coolify`.
- Para expor o SQL Server externamente (ex: acesso de ferramenta de gerenciamento), use um túnel ou VPN — nunca exponha a porta `1433` diretamente na internet.
- O `forceencryption = 0` no `mssql.conf` é intencional para tráfego interno entre containers. Se o SQL Server precisar ser acessível de fora do host, configure um certificado TLS e defina `forceencryption = 1`.

---

*Stack para produção — versão fixada, recursos controlados, init automatizado.*
