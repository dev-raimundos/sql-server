# SQL Server 2022 — Homelab Stack

> Stack Docker para SQL Server 2022 Developer Edition, com limites de recursos definidos e automação via Taskfile.

---

## O que é isso

Este repositório contém a configuração completa para subir o **SQL Server 2022** via Docker Compose. A edição Developer é funcionalmente idêntica à Enterprise — mesma feature set, mesmos limites de recursos — mas licenciada apenas para desenvolvimento e teste, sem custo.

A stack foi construída para um homelab com recursos limitados. Os limites de memória estão explícitos no compose, o Taskfile cobre as operações do dia a dia, e a imagem está fixada em uma versão específica para evitar atualizações involuntárias.

---

## Arquitetura

```
Cliente SQL
   │
   │  :1433 (TCP)
   ▼
┌─────────────────────────────┐
│   Nginx Proxy Manager       │  ← TCP Stream apontando para :1433
└──────────────┬──────────────┘
               │
               ▼  :1433
┌─────────────────────────────┐
│       SQL Server 2022       │  ← Developer Edition
│                             │
│  /var/opt/mssql             │  ← dados persistidos via bind mount (host)
└─────────────────────────────┘
```

O SQL Server expõe apenas a porta `1433` (protocolo TDS). O Nginx Proxy Manager faz o roteamento TCP via **Stream** — diferente de hosts HTTP, conexões SQL precisam ser configuradas na aba Streams do painel do NPM, não em Proxy Hosts.

---

## Engenharia das decisões

### Limites de recursos (`deploy.resources`)

O SQL Server, por padrão, não impõe limite interno de memória — ele consome o máximo disponível no host à medida que recebe carga. Este host tem 16 GB de RAM e também roda o Nginx Proxy Manager, então isso pode derrubar o sistema inteiro.

O limite é aplicado em duas camadas complementares:

| Camada | Valor | O que faz |
|-----------|-----------|-----------------|
| `deploy.resources.limits.memory` (cgroup, Docker) | 10240 MB | Teto rígido. Se ultrapassado, o kernel mata o processo na hora (OOM-kill), sem checkpoint gracioso. |
| `MSSQL_MEMORY_LIMIT_MB` (motor do SQL Server) | 8192 MB | Teto interno, cobrindo todo o processo (buffer pool, SQLPAL, etc). O motor reage bem antes do limite do cgroup, liberando cache de forma gradual em vez de ser morto abruptamente. |
| `deploy.resources.limits.cpus` (cgroup, Docker) | 3.0 | Deixa 1 das 4 threads lógicas do i3-3220T livre para o NPM e o SO. |
| `deploy.resources.reservations.memory` | 2048 MB | Soft-limit real (`HostConfig.MemoryReservation`) — o kernel usa isso para decidir de quem tirar memória primeiro sob pressão do host. |

A folga de ~20% entre `MSSQL_MEMORY_LIMIT_MB` (8192) e o limite do cgroup (10240) segue a recomendação da Microsoft, dando ao motor espaço para reagir antes do OOM-kill. Os 6 GB restantes fora do container ficam para o SO e o Nginx Proxy Manager.

> **Atenção:** `deploy.resources.reservations.cpus` **não tem efeito nenhum** rodando via `docker compose up` sem Swarm (não mapeia para nenhuma configuração real do container) — por isso não está no compose. Já `reservations.memory` tem efeito real mesmo fora do Swarm. Testado empiricamente com `docker inspect --format '{{.HostConfig.MemoryReservation}}'`.

### Imagem fixada por versão (`2022-CU25-ubuntu-22.04`)

A tag `2022-latest` avança automaticamente a cada Cumulative Update lançado pela Microsoft. Isso pode introduzir mudanças comportamentais ou de compatibilidade sem aviso. A tag fixa `2022-CU25-ubuntu-22.04` garante que o ambiente seja reproduzível — a mesma imagem sempre, até que a atualização seja uma decisão explícita.

Para atualizar: substituir `CU25` pelo número do CU desejado no `compose.yaml`.

### Criação automática do usuário de healthcheck

O healthcheck do `compose.yaml` conecta com um usuário próprio (`healthcheck_user`), não com `sa`, para não expor a senha administrativa a uma rotina que só faz `SELECT 1`. O problema: esse usuário só existe depois que o banco cria — e o banco só existe depois que o container sobe pela primeira vez. Se o healthcheck começar a rodar antes disso, ele falha, o container fica `unhealthy` e cai antes de ter chance de criar o próprio usuário que precisa.

A solução é um `Dockerfile` que substitui o entrypoint padrão da imagem por [`docker/entrypoint.sh`](docker/entrypoint.sh): ele sobe o `sqlservr` normalmente e, em paralelo, dispara [`docker/create-healthcheck-user.sh`](docker/create-healthcheck-user.sh), que:

1. Espera o SQL Server aceitar conexões (poll com `sqlcmd`, até 90s).
2. Cria o login `HEALTHCHECK_USER` (se não existir) ou sincroniza a senha (se já existir) via [`docker/create-healthcheck-user.sql`](docker/create-healthcheck-user.sql).
3. Concede apenas `CONNECT SQL` — o mínimo necessário pra rodar `SELECT 1`, sem acesso a nenhum banco.

Isso roda em todo start do container (não só no primeiro), então também cobre o caso de rotacionar `HEALTHCHECK_PASSWORD` no `.env` — na próxima subida a senha do login é atualizada.

#### Recriando o volume de dados do zero

O processo do SQL Server dentro do container roda como o usuário `mssql` (UID `10001`), não como `root`. Se `/home/docker-data/sqlserver` for apagado e recriado no host, a pasta volta a pertencer a `root` e o `sqlservr` falha ao iniciar com `Permission denied` ao tentar criar seus próprios arquivos internos. Antes de subir o container com um volume novo, ajuste a posse da pasta no host:

```bash
sudo mkdir -p /home/docker-data/sqlserver
sudo chown -R 10001:0 /home/docker-data/sqlserver
```

> Evite aspas simples (`'`) em `HEALTHCHECK_PASSWORD` — a substituição de variáveis do `sqlcmd -v` não escapa esse caractere.

### Bind mount ao invés de named volume

Os dados ficam em uma pasta do host (`/home/docker-data/sqlserver`) mapeada diretamente para `/var/opt/mssql`, em vez de um named volume gerenciado pelo Docker. Isso dá visibilidade e acesso direto no host para ferramentas externas de backup/monitoramento, e deixa explícito em qual disco/partição os dados residem. O trade-off é ter que gerenciar manualmente a posse da pasta (usuário `mssql`, UID `10001`) — ver a subseção "Recriando o volume de dados do zero" acima.

A pasta `./data` no repositório existe como ponto de transferência manual para arquivos de backup (via `task export-backup` / `task import-backup`), não como volume de dados principal.

### SQL Server Agent habilitado

`MSSQL_AGENT_ENABLED: "true"` no `compose.yaml` — o Agent está ativo para execução de jobs agendados. O overhead ocioso é baixo (~20-50 MB de RAM), mas o consumo real depende do que os jobs configurados fazem.

### Variáveis de ambiente via `.env`

As credenciais ficam em um arquivo `.env` separado do `compose.yaml`. Isso permite versionar o compose no Git sem expor a senha do `sa`. O `.env.example` documenta as variáveis sem valores reais e pode ser versionado normalmente.

### Taskfile para operações do dia a dia

As operações mais comuns (conectar, fazer backup, restaurar, exportar arquivos) têm comandos prontos no `Taskfile.yml`. Isso evita memorizar flags de `docker exec` e caminhos internos do container.

---

## Estrutura do repositório

```
.
├── compose.yaml      # definição do serviço
├── Dockerfile         # customiza a imagem oficial com o entrypoint abaixo
├── docker/
│   ├── entrypoint.sh                  # sobe o sqlservr + dispara a criação do usuário de healthcheck
│   ├── create-healthcheck-user.sh     # espera o banco ficar pronto e roda o script SQL
│   └── create-healthcheck-user.sql    # cria/sincroniza o login de healthcheck
├── Taskfile.yml      # automação de operações comuns
├── .env              # credenciais (não versionar)
├── .env.example      # modelo sem valores reais (pode versionar)
└── data/             # ponto de transferência de backups (não é o volume de dados)
```

---

## Como usar

**1. Configure as credenciais**

```bash
cp .env.example .env
```

Edite o `.env` com uma senha forte para o usuário `sa`:

```
MSSQL_SA_PASSWORD=Sua_Senha_Forte_Aqui
MSSQL_PID=Developer
ACCEPT_EULA=Y
```

> A senha precisa ter no mínimo 8 caracteres com maiúscula, minúscula, número e símbolo — o SQL Server recusa senhas fracas na inicialização.

**2. Suba a stack**

```bash
task up
```

**3. Verifique se o banco está pronto**

```bash
task logs
```

O SQL Server leva alguns segundos para inicializar. Quando aparecer `SQL Server is now ready for client connections`, está pronto.

**4. Conecte ao banco**

```bash
task connect
```

---

## Taskfile — referência rápida

| Comando | O que faz |
|---|---|
| `task up` | Sobe em background |
| `task down` | Para e remove containers |
| `task stop` | Para sem remover |
| `task restart` | Reinicia |
| `task status` | Status dos containers |
| `task logs` | Logs em tempo real |
| `task shell` | Bash dentro do container |
| `task connect` | sqlcmd interativo como `sa` |
| `task query -- "SELECT @@VERSION"` | Query avulsa |
| `task databases` | Lista todos os bancos |
| `task backup -- MinhaDB` | Backup de um banco |
| `task restore -- MinhaDB /caminho/arquivo.bak` | Restaura um backup |
| `task export-backup -- arquivo.bak` | Copia backup do container para `./data` |
| `task import-backup -- arquivo.bak` | Copia backup de `./data` para o container |
| `task reset` | **Destrói tudo**, incluindo volume de dados (pede confirmação) |

---

## Nginx Proxy Manager — configuração TCP

O NPM não faz proxy de SQL Server via Proxy Hosts (HTTP). Use a aba **Streams**:

1. Acesse o painel do NPM → **Streams** → **Add Stream**
2. **Incoming Port:** porta pública desejada (ex. `1433`)
3. **Forward Host:** IP ou hostname do servidor onde o SQL Server roda
4. **Forward Port:** `1433`
5. Salve — sem SSL, protocolo TCP puro

---

## Requisitos

- Docker Engine 24+
- Docker Compose v2 (plugin, não o `docker-compose` legado)
- [Task](https://taskfile.dev) instalado (`task --version`)
- Porta `1433` livre no host

---

## Notas de segurança

- O arquivo `.env` **nunca** deve ser commitado no Git.
- O usuário `sa` tem acesso total ao servidor SQL. Em produção, crie usuários com permissões mínimas por banco.
- Não exponha a porta `1433` diretamente para a internet sem autenticação de rede adicional (VPN ou firewall).

---

*Homelab pessoal — hardware modesto, configuração honesta.*
