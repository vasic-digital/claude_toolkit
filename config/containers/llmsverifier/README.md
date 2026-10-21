# LLMsVerifier System — nezha deployment

Boots the LLMsVerifier production stack on the remote host **nezha.local**
(registered in `../nezha.env`) for heavy testing that depends on real
production services. The `containers` submodule provides the distributed-boot
orchestration capability; this overlay is the concrete service set.

## What runs (all health-verified on nezha)

| Service | Image | Port (loopback) | Verified |
|---------|-------|-----------------|----------|
| llm-verifier | `llm-verifier:nezha` (built from `Dockerfile.nezha`) | 127.0.0.1:8080 | `/api/health` → 200 `{"status":"healthy","database":"connected"}` |
| postgres | postgres:15-alpine | 127.0.0.1:55432 | `pg_isready` + `SELECT` |
| redis | redis:7-alpine | 127.0.0.1:56379 | `AUTH` + `PING`/`SET`/`GET` |
| prometheus | prom/prometheus | 127.0.0.1:59090 | `/-/healthy` 200, `/-/ready`, `query=up` |
| grafana | grafana/grafana | 127.0.0.1:53000 | `/api/health` `database:ok` |

All ports bound to `127.0.0.1` on nezha (security review). Remote access via SSH
tunnel, e.g. `ssh -L 8080:127.0.0.1:8080 milosvasic@nezha.local`.

## Boot procedure

```bash
# On the orchestrator host (paths assume this repo):
rsync -az --exclude='.git' "$(bash scripts/resolve_deps.sh llms_verifier)/" milosvasic@nezha.local:~/helix-build/LLMsVerifier/
# challenges is no longer a submodule of this repo: resolve it first
#   CHALLENGES="$(bash scripts/resolve_deps.sh challenges)"
rsync -az --exclude='.git' "$CHALLENGES"/   milosvasic@nezha.local:~/helix-build/challenges/
scp config/containers/llmsverifier/Dockerfile.nezha milosvasic@nezha.local:~/helix-build/

# Build the app image on nezha (cgo + nested module — see Dockerfile.nezha):
ssh milosvasic@nezha.local 'cd ~/helix-build && podman build -f Dockerfile.nezha -t llm-verifier:nezha .'

# Stage the overlay + generate secrets (.env never committed):
ssh milosvasic@nezha.local 'mkdir -p ~/helix-system/llmsverifier'
scp config/containers/llmsverifier/{docker-compose.infra.yml,docker-compose.app.yml,prometheus.yml,config.yaml.template} \
    milosvasic@nezha.local:~/helix-system/llmsverifier/
# Generate ~/helix-system/llmsverifier/.env with POSTGRES_PASSWORD, REDIS_PASSWORD,
# GRAFANA_ADMIN_PASSWORD, DATABASE_ENCRYPTION_KEY, JWT_SECRET (openssl rand), chmod 600.
# Render config.yaml from config.yaml.template substituting the two secrets, chmod 600.

# Boot:
ssh milosvasic@nezha.local 'cd ~/helix-system/llmsverifier && \
  podman-compose -f docker-compose.infra.yml up -d && \
  podman-compose -f docker-compose.app.yml up -d'
```

## Issues discovered + root-caused (systematic-debugging)

The upstream `LLMsVerifier/docker-compose.prod.yml` + `Dockerfile` are
ops-coupled and could not deploy verbatim. Each was root-caused, not patched
blindly:

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| A | compose mounts `scripts/init.sql`, `nginx/nginx.conf`, `nginx/ssl` | files never committed (no `nginx/` dir); deploy config absent | overlay omits nginx + init mount (app uses SQLite; nginx optional) |
| B | `go mod download` fails on `../challenges` | `replace digital.vasic.challenges => ../challenges` is outside the Docker context `.` | added `challenges` submodule; build the self-contained nested module (no challenges needed) |
| C | prometheus exits (2) | `prometheus.yml` had top-level `storage:`/`web:` (those are CLI flags, not config fields) | sanitized config; `/-/healthy` 200 |
| D | `open /app/llm-verifier/go.mod: no such file` | multi-module repo: `replace … => ./llm-verifier` subdir; upstream Dockerfile downloads before copying source | build the nested module standalone |
| E | `missing go.sum entry for bubbletea/lipgloss/cobra` | app is the nested module `digital.vasic.llmsverifier`; building from top module used the wrong go.sum; `cmd/` is multi-file `package main` | build `./cmd` package inside the nested module |
| F | `error reading config file: open config.yaml` | `server` requires `--config config.yaml`; none present | mount generated `config.yaml` (DB path → persistent volume) |
| G | `config.yaml: permission denied` | container runs as `appuser`(65532); host-600 bind mount unreadable across rootless userns | `:ro,U` mount flag chowns to container user |
| H | `/health` → 404 | real route is `/api/health` (upstream prod compose healthcheck wrong) | healthcheck + probes use `/api/health` |
| I | model verification → HTTP 401 for every provider (valid keys) | `verification/code_verification.go` sent the chat request with NO `Authorization` header | `patches/0001-verification-add-auth-header.patch` (Bearer `GetAPIKey()`); RED 401 → GREEN verified (DeepSeek 0.78, Groq 0.98) — see `docs/qa/20260616-infra/verification-proof.md` |

## Heavy testing (real LLM verification)

With provider keys present in the on-host `.env`, the bundled `model-verification`
tool runs real "Do you see my code?" checks against live provider APIs:

```bash
ssh milosvasic@nezha.local 'podman run --rm --env-file ~/helix-system/llmsverifier/.env \
  llm-verifier-mv:nezha --provider deepseek --model deepseek-chat --verbose'
```

Verified live: DeepSeek `deepseek-chat` → `verified` (score 0.78), Groq
`llama-3.3-70b-versatile` → `verified` (score 0.98). The `0001-...patch` must be
applied to the build context first (it is, in the nezha build).

`mattn/go-sqlite3` (cgo) forced `CGO_ENABLED=1` + an alpine (musl) runtime —
the upstream `CGO_ENABLED=0` static build cannot link it.

## Security (review-addressed)

- All published ports bound to `127.0.0.1` (no `0.0.0.0`).
- `${VAR:?required}` fail-fast on every secret (no fail-open).
- Secrets live only in the on-host `.env` + `config.yaml` (mode 600), never in
  the repo. Accepted LAN-test-host tradeoffs: redis password in argv, `:latest`
  tags (documented, not blocking).
