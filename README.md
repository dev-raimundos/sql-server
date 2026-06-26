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
│  /var/opt/mssql             │  ← dados persistidos em named volume
└─────────────────────────────┘
```

O SQL Server expõe apenas a porta `1433` (protocolo TDS). O Nginx Proxy Manager faz o roteamento TCP via **Stream** — diferente de hosts HTTP, conexões SQL precisam ser configuradas na aba Streams do painel do NPM, não em Proxy Hosts.

---

## Engenharia das decisões

### Limite de 6 GB de RAM (`deploy.resources`)

O SQL Server, por padrão, não impõe limite interno de memória — ele consome o máximo disponível no host à medida que recebe carga. Em um servidor compartilhado com outros serviços, isso pode derrubar o sistema inteiro.

O limite de 6 GB é um teto no nível do Docker (cgroups), aplicado independentemente do que o SQL Server tenta alocar:

| Container | RAM limit | RAM reservation |
|-----------|-----------|-----------------|
| SQL Server | 6 GB | 512 MB |

A reservation garante que o container sempre tenha 512 MB disponíveis mesmo sob pressão de memória no host.

### Imagem fixada por versão (`2022-CU25-ubuntu-22.04`)

A tag `2022-latest` avança automaticamente a cada Cumulative Update lançado pela Microsoft. Isso pode introduzir mudanças comportamentais ou de compatibilidade sem aviso. A tag fixa `2022-CU25-ubuntu-22.04` garante que o ambiente seja reproduzível — a mesma imagem sempre, até que a atualização seja uma decisão explícita.

Para atualizar: substituir `CU25` pelo número do CU desejado no `compose.yaml`.

### Named volume ao invés de bind mount

Os dados ficam em um named volume gerenciado pelo Docker (`sqlserver_data`) em vez de uma pasta local mapeada. Named volumes têm melhor performance em Linux e evitam problemas de permissão — o SQL Server dentro do container roda com um usuário não-root específico que pode não ter acesso a pastas do host.

A pasta `./data` no repositório existe como ponto de transferência manual para arquivos de backup (via `task export-backup` / `task import-backup`), não como volume de dados principal.

### Variáveis de ambiente via `.env`

As credenciais ficam em um arquivo `.env` separado do `compose.yaml`. Isso permite versionar o compose no Git sem expor a senha do `sa`. O `.env.example` documenta as variáveis sem valores reais e pode ser versionado normalmente.

### Taskfile para operações do dia a dia

As operações mais comuns (conectar, fazer backup, restaurar, exportar arquivos) têm comandos prontos no `Taskfile.yml`. Isso evita memorizar flags de `docker exec` e caminhos internos do container.

---

## Estrutura do repositório

```
.
├── compose.yaml      # definição do serviço
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
