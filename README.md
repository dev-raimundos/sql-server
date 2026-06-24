# SQL Server 2022

SQL Server 2022 Developer Edition em container Docker.

## Requisitos

- Docker + Docker Compose

## Configuração

Copie o arquivo de exemplo e ajuste a senha:

```bash
cp .env.example .env
```

Variáveis disponíveis no `.env`:

| Variável | Descrição | Padrão |
|---|---|---|
| `MSSQL_SA_PASSWORD` | Senha do usuário `sa` | — |
| `MSSQL_PID` | Edição do SQL Server | `Developer` |
| `ACCEPT_EULA` | Aceite do contrato de licença | `Y` |

> A senha precisa ter no mínimo 8 caracteres com maiúscula, minúscula, número e símbolo.

## Uso

```bash
# Subir
docker compose up -d

# Ver logs
docker compose logs -f

# Parar
docker compose down
```

## Conexão

| Campo | Valor |
|---|---|
| Host | `localhost` |
| Porta | `1433` |
| Usuário | `sa` |
| Senha | definida em `MSSQL_SA_PASSWORD` |

## Recursos

- Imagem: `mcr.microsoft.com/mssql/server:2022-CU25-ubuntu-22.04`
- Memória máxima: 6 GB
- Dados persistidos em named volume Docker (`sqlserver_data`)

## Deploy via Coolify

Aponte o Coolify para este repositório e configure as variáveis de ambiente equivalentes ao `.env`. A rede do Coolify é injetada automaticamente — não é necessário nenhuma configuração adicional de rede.
