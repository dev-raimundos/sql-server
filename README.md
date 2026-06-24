# SQL Server Developer — Production Stack

> Stack Docker para SQL Server 2022 com versão fixada e limite de 6 GB de RAM.

---

## O que é isso

Este repositório contém a configuração mínima para subir o **SQL Server 2022 Developer Edition** via Docker Compose em um servidor gerenciado pelo **Coolify**. Usa a imagem oficial sem modificações — sem Dockerfile customizado, sem entrypoint próprio, sem scripts automáticos de init. Menos peças, menos falhas.

---

## Arquitetura

```
Coolify (rede: coolify)
         │
         │  hostname: sqlserver
         │  porta interna: 1433
         ▼
┌──────────────────────────────────────┐
│             sqlserver                │
│                                      │
│   SQL Server 2022 Developer CU16     │
│   limit: 6 GB RAM / 5,6 GB mssql    │
│                                      │
│   imagem oficial — sem customização  │
└──────────────┬───────────────────────┘
               │
    ┌──────────┴──────────────────────┐
    │  sqlserver-data (named volume)  │  ← todos os dados do SQL Server
    └─────────────────────────────────┘
```

---

## Engenharia das decisões

### Imagem oficial sem Dockerfile customizado

A versão anterior usava um `Dockerfile` e um `entrypoint.sh` próprios para gerar certificado TLS, escrever `mssql.conf` e executar scripts de init SQL na primeira inicialização. O problema: o entrypoint rodava com `set -eo pipefail` e qualquer falha (timeout de retry, permissão negada, comando com saída não-zero) encerrava o processo — o container saía com erro e entrava em loop de restart até atingir o limite do Coolify.

A imagem oficial tem seu próprio entrypoint battle-tested que lida com todos esses casos. Usar a imagem diretamente elimina essa camada de falha.

### Tag de imagem fixa (`2022-CU16-ubuntu-22.04`)

A tag `latest` ou `2022-latest` muda a cada Cumulative Update lançado pela Microsoft. Uma atualização silenciosa pode quebrar comportamentos em produção. A tag fixa garante que o ambiente é idêntico entre deploys.

### Limite de memória duplo

**Docker** (`deploy.resources.limits.memory: 6g`) — o kernel mata o container se ele tentar alocar além desse valor. É o teto absoluto.

**SQL Server** (`MSSQL_MEMORY_LIMIT_MB=5632`) — o servidor é configurado para não alocar mais que 5,5 GB para o buffer pool. Os ~512 MB restantes ficam disponíveis para o SO do container e as threads do SQL Server. Sem esse ajuste, o SQL Server tentaria usar toda a RAM disponível e o OOM Killer encerraria o processo.

### Named volume único

Um único named volume em `/var/opt/mssql` armazena tudo: system databases, dados da aplicação, logs e configuração. O Docker gerencia permissões automaticamente — na primeira execução, copia o conteúdo da imagem para o volume com o owner correto (`mssql`). Isso elimina o problema de permissão que um bind mount `./data` criaria (diretório criado pelo Docker/Coolify com owner `root`, inacessível pelo processo `mssql`).

### TLS e certificado

O SQL Server gera um certificado autoassinado automaticamente. Para conexões internas (app ASP.NET → SQL Server dentro da rede `coolify`), usar `TrustServerCertificate=true` na connection string encripta o tráfego sem necessidade de distribuir certificados. Para conexões externas via SSMS, marcar "Trust Server Certificate" na tela de conexão tem o mesmo efeito.

### Criação de banco e usuário fora do container

Scripts de init dentro do container criam acoplamento entre a infraestrutura e o schema da aplicação, e são uma fonte comum de falhas no startup. A responsabilidade de criar o banco e o usuário fica com quem tem o contexto: a aplicação (via EF Core Migrations) ou o operador (via SSMS ou `sqlcmd` manual). O arquivo `init/01-init-db.sql` existe como referência para execução manual.

### Rede `coolify` como `external: true`

O Coolify cria e gerencia a rede `coolify` fora do ciclo de vida de qualquer compose individual. Sem `external: true`, um `docker compose down` tentaria remover a rede e derrubaria todos os outros containers conectados.

---

## Estrutura do repositório

```
.
├── compose.yaml          # definição do serviço
├── .env                  # credenciais (não versionar)
├── .env.example          # modelo sem valores reais
├── .gitignore
└── init/
    └── 01-init-db.sql    # referência para criação manual do banco e usuário
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
SQL_PORT=1433
TZ=America/Sao_Paulo
```

**2. Suba via Coolify**

Aponte o Coolify para este repositório com tipo **Docker Compose**.

Ou manualmente:

```bash
docker compose up -d
```

**3. Crie o banco e o usuário (primeira vez)**

Edite `init/01-init-db.sql` com o nome do banco, usuário e senha desejados. Depois execute via SSMS ou:

```bash
docker exec -it sqlserver /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$SA_PASSWORD" \
  -i /tmp/01-init-db.sql -C -N d
```

**4. Connection string na aplicação ASP.NET**

```
Server=sqlserver,1433;Database=NomeDoBanco;User Id=appuser;Password=...;Encrypt=true;TrustServerCertificate=true;
```

**5. Conectar via SSMS ou Azure Data Studio**

| Campo | Valor |
|---|---|
| Server Name | `IP-DO-SERVIDOR,1433` |
| Authentication | SQL Server Authentication |
| Login | `sa` |
| Encrypt | Optional |
| Trust Server Certificate | ✅ |

**6. Backup manual**

```bash
docker exec -it sqlserver /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$SA_PASSWORD" -C -N d \
  -Q "BACKUP DATABASE [NomeDoBanco] TO DISK = N'/var/opt/mssql/backup/NomeDoBanco.bak' WITH FORMAT"
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
- O usuário da aplicação não deve ser `sa`. Crie um usuário com permissões mínimas (`db_datareader`, `db_datawriter`, `EXECUTE`) usando `init/01-init-db.sql`.
- A porta `1433` não é exposta publicamente — acessível apenas por containers na rede `coolify`.
- Para acesso externo (SSMS), use um túnel ou VPN. Nunca exponha a porta `1433` diretamente na internet.

---

*Stack para produção — imagem oficial, configuração mínima, sem pontos extras de falha.*
