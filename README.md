# SQL Server Developer — Production Stack

> Stack Docker para SQL Server 2022 com versão fixada, limite de 6 GB de RAM, TLS automático e inicialização automatizada do banco da aplicação.

---

## O que é isso

Este repositório contém a configuração completa para subir o **SQL Server 2022 Developer Edition** via Docker Compose em um servidor gerenciado pelo **Coolify**. A stack cria automaticamente o banco de dados e o usuário da aplicação na primeira inicialização, gera um certificado TLS autoassinado, persiste os dados no diretório `/data` e integra com a rede interna do Coolify para que outros containers (como a aplicação ASP.NET) alcancem o banco pelo hostname `sqlserver`.

---

## Arquitetura

```
Coolify (rede: coolify)
         │
         │  hostname: sqlserver
         │  porta interna: 1433 (TLS)
         ▼
┌─────────────────────────────────────┐
│            sqlserver                │
│                                     │
│   SQL Server 2022 Developer CU16    │
│   limit: 6 GB RAM / 5,6 GB mssql   │
│                                     │
│  /var/opt/mssql  ← system databases │
│  /var/opt/mssql/ssl ← certificado  │
│  /data/db        ← MDF da aplicação │
│  /data/log       ← LDF da aplicação │
│  /data/backup    ← backups          │
└──────────┬──────────────────────────┘
           │
    ┌──────┴──────────────────────────┐
    │  sqlserver-system (named vol.)  │  ← master, msdb, model, tempdb, cert, mssql.conf
    │  ./data          (bind mount)   │  ← arquivos do banco da aplicação
    └─────────────────────────────────┘
```

O container da aplicação ASP.NET, também gerenciado pelo Coolify, alcança o SQL Server pelo hostname `sqlserver` dentro da rede `coolify`. Nenhuma porta é exposta publicamente.

---

## Engenharia das decisões

### Tag de imagem fixa (`2022-CU16-ubuntu-22.04`)

A tag `latest` ou `2022-latest` muda silenciosamente a cada Cumulative Update lançado pela Microsoft. Em produção isso significa que um `docker compose pull` pode trocar a versão do servidor sem aviso, quebrando comportamentos ou exigindo testes de regressão não planejados.

A tag `2022-CU16-ubuntu-22.04` fixa exatamente a versão do SQL Server e a distro base. Para atualizar, a decisão é explícita e controlada — basta mudar a tag no `Dockerfile` e reconstruir.

### Imagem customizada via `Dockerfile`

O SQL Server não tem o equivalente ao `/docker-entrypoint-initdb.d/` do PostgreSQL. A imagem oficial inicia o servidor e para por aí — não há mecanismo nativo para rodar scripts SQL após a primeira inicialização.

O `Dockerfile` adiciona um `entrypoint.sh` que roda como `root` e executa na ordem:

1. Cria os subdiretórios de `/data` com as permissões corretas para o `mssql` user.
2. Gera o certificado TLS autoassinado (apenas na primeira execução).
3. Escreve o `mssql.conf` no volume com as configurações de memória, TLS e telemetria.
4. Inicia o `sqlservr` via `runuser -u mssql` (dropping de privilégios).
5. Aguarda o servidor aceitar conexões (com timeout e retry).
6. Executa todos os arquivos `.sql` e `.sh` de `/docker-entrypoint-initdb.d` em ordem alfabética.
7. Aguarda o processo principal encerrar.

### `root` no entrypoint + `runuser` para o servidor

O container roda com o entrypoint como `root` porque o bind mount `./data` chega no container com owner `root` (criado pelo Docker/Coolify no host) — o `mssql` user não consegue criar subdiretórios nele. Após o setup, `runuser -u mssql` garante que o `sqlservr` rode sem privilégios.

Definir `USER mssql` no `Dockerfile` e tentar fazer o `chown` do bind mount em runtime resultaria em `Permission denied` — o `chown` no `RUN` do Dockerfile só afeta a camada da imagem, que é substituída pelo bind mount em runtime.

### `mssql.conf` gerado em runtime (não montado como arquivo)

Montar um arquivo diretamente dentro de um diretório que também é um named volume (`sqlserver-system:/var/opt/mssql` + `./config/mssql.conf:/var/opt/mssql/mssql.conf`) faz o Docker criar o caminho do arquivo como um **diretório vazio** dentro do volume — o SQL Server tenta abri-lo como arquivo e falha com `STATUS_FILE_IS_A_DIRECTORY`.

A solução é escrever o `mssql.conf` programaticamente no `entrypoint.sh` após os volumes serem montados. Como o entrypoint roda como `root` e escreve dentro do named volume, não há conflito.

### Certificado TLS autoassinado gerado em runtime

Na primeira inicialização, o `entrypoint.sh` gera um certificado RSA 2048 bits via `openssl` com validade de 10 anos e SAN para `sqlserver`, `localhost` e `127.0.0.1`. O certificado é salvo em `/var/opt/mssql/ssl/` dentro do named volume — persiste entre redeployments e só é gerado uma vez.

O `mssql.conf` gerado aponta para esse certificado e define `forceencryption = 1`, garantindo que todas as conexões sejam encriptadas.

A aplicação ASP.NET **não precisa dos arquivos de certificado**. Usando `TrustServerCertificate=true` na connection string, o tráfego continua encriptado — a flag apenas desativa a validação da identidade do servidor, não a criptografia. Para serviços internos dentro da mesma rede Docker, isso é o comportamento padrão e correto.

### Dois volumes separados

**`sqlserver-system` (named volume → `/var/opt/mssql`)** armazena os bancos de sistema (`master`, `msdb`, `model`, `tempdb`), o certificado TLS e o `mssql.conf`. É gerenciado pelo Docker e não precisa ser acessível diretamente no host.

**`./data` (bind mount → `/data`)** armazena os arquivos `.mdf` e `.ldf` do banco da aplicação. Sendo um bind mount, os arquivos ficam visíveis e acessíveis na máquina host — útil para backups externos e migração sem depender do Docker volume CLI.

### Limite de memória duplo

O limite de 6 GB é aplicado em duas camadas:

**Docker** (`deploy.resources.limits.memory: 6g`) — o kernel mata o container se ele tentar alocar além desse valor. É o teto absoluto.

**SQL Server** (`memorylimitmb = 5632` no `mssql.conf`) — o servidor é configurado para não alocar mais que 5,5 GB para o buffer pool. Os ~512 MB restantes ficam disponíveis para o SO do container e as threads do próprio SQL Server. Sem esse ajuste, o SQL Server tentaria usar toda a RAM disponível e o Docker OOM Killer encerraria o processo de forma abrupta.

### Healthcheck com `sqlcmd`

O check executa um `SELECT 1` via `sqlcmd` dentro do próprio container. O `start_period: 90s` dá margem para a inicialização completa antes de começar a contar as retries. As flags `-C -N d` desativam a verificação de certificado e a criptografia forçada para a conexão local de healthcheck — o loopback não precisa de TLS.

### Init SQL idempotente

O script `init/01-init-db.sql` usa `IF NOT EXISTS` em todas as operações — pode ser executado múltiplas vezes sem efeitos colaterais. O usuário da aplicação recebe apenas `db_datareader`, `db_datawriter` e `EXECUTE`, sem acesso a DDL. A senha do `sa` fica separada e é usada somente internamente pela stack.

### Rede `coolify` como `external: true`

O Coolify cria e gerencia a rede `coolify` fora do ciclo de vida de qualquer compose individual. Declarar `external: true` informa ao Docker Compose que ele não deve criar, modificar ou destruir essa rede. Sem isso, um `docker compose down` tentaria remover a rede do Coolify e derrubaria todos os outros containers conectados.

---

## Estrutura do repositório

```
.
├── compose.yaml            # definição dos serviços
├── Dockerfile              # imagem customizada com entrypoint de init
├── .env                    # credenciais (não versionar)
├── .env.example            # modelo sem valores reais (pode versionar)
├── .gitignore
├── scripts/
│   └── entrypoint.sh       # setup de dirs, geração de cert, mssql.conf, init scripts
├── init/
│   └── 01-init-db.sql      # cria banco e usuário da aplicação
└── data/                   # arquivos MDF/LDF gerados em runtime (não versionar)
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

**4. Connection string na aplicação ASP.NET**

```
Server=sqlserver,1433;Database=NomeDoBanco;User Id=appuser;Password=...;Encrypt=true;TrustServerCertificate=true;
```

**5. Conectar via SSMS ou Azure Data Studio**

Para confiar no certificado sem precisar importá-lo:

| Campo | Valor |
|---|---|
| Server Name | `IP-DO-SERVIDOR,1433` |
| Authentication | SQL Server Authentication |
| Login | `sa` |
| Encrypt | Optional ou Mandatory |
| Trust Server Certificate | ✅ |

Para validação completa do certificado, exporte e importe no Windows:

```bash
docker cp <container-name>:/var/opt/mssql/ssl/mssql.pem ./mssql.pem
```

```powershell
Import-Certificate -FilePath .\mssql.pem -CertStoreLocation Cert:\LocalMachine\Root
```

**6. Backup manual**

```bash
docker exec -it <container-name> /opt/mssql-tools18/bin/sqlcmd \
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
- Para acesso externo (ex: SSMS), use um túnel ou VPN — nunca exponha a porta `1433` diretamente na internet.
- O certificado gerado é autoassinado. `TrustServerCertificate=true` encripta o tráfego mas não valida a identidade do servidor — aceitável para serviços internos. Para validação completa, distribua o `mssql.pem` e instale-o no trust store dos clientes.

---

*Stack para produção — versão fixada, recursos controlados, TLS automático, init automatizado.*
