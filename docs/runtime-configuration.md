# Runtime configuration reference

- Scope: pinned Docker Compose runtime from `T-0005`
- Target: one Ubuntu 24.04 LTS x86_64 VPS
- Canonical architecture: [docs/architecture.md](architecture.md)
- Version evidence: [ADR-0003](../adr/0003-version-pinning-policy.md)
- Registry fallback: [ADR-0012](../adr/0012-timeweb-dockerhub-proxy-fallback.md)

## Files

| Path | Purpose |
|---|---|
| `docker-compose.yml` | n8n, PostgreSQL and Caddy services, networks, volumes and health checks |
| `.env.example` | documented variables without credential values |
| `config/Caddyfile` | HTTPS termination, reverse proxy, active upstream health and response headers |
| `tests/fixtures/compose.env` | known fake values for static Compose validation only |

Do not deploy `tests/fixtures/compose.env`. It is intentionally public, contains no usable secrets and uses the reserved `.test` domain.

## Required user values

Copy `.env.example` to `.env` and set:

- `N8N_HOST`: optional custom public FQDN; empty on first install selects `n8n-<public-ip>.sslip.io`;
- `ACME_EMAIL`: optional legacy contact value; default Caddy path does not require it;
- `TIMEZONE`: IANA timezone such as `Europe/Moscow`;
- `POSTGRES_PASSWORD`: independently generated random secret;
- `N8N_ENCRYPTION_KEY`: independently generated persistent random secret.

The encryption key must never change during update. Losing it makes stored n8n credentials unreadable. `.env` must have mode `0600`, remain outside Git and be included in protected backup material.

`EXECUTIONS_DATA_MAX_AGE=168` and `EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000` are privacy-minded training defaults. Reduce them for sensitive/high-volume workflows after understanding the diagnostic tradeoff.

`N8N_IMAGE_SOURCE=official` сохраняет канонические registry references.
Timeweb onboarding явно выбирает `timeweb`; installer записывает allowlisted
`POSTGRES_IMAGE`, `N8N_IMAGE_REPOSITORY` и `CADDY_IMAGE` с теми же exact tags через
официальный proxy провайдера. Произвольные registry overrides не входят в
beginner contract.

The Compose environment always keeps `EXECUTIONS_DATA_PRUNE=true`. Overrides change the age/count bounds, not the fact that pruning is enabled. See [security baseline](security.md) for examples and the evidence boundary.

## Service topology

```text
Internet → Caddy :80/:443 → n8n :5678 → PostgreSQL :5432
```

- Only Caddy publishes host ports. UDP `443` enables HTTP/3; TCP `80/443` handle ACME, HTTP/1.1 and HTTP/2.
- `frontend` connects Caddy and n8n and permits n8n outbound provider calls.
- internal `backend` connects only n8n and PostgreSQL; PostgreSQL has no host port.
- Named volumes preserve PostgreSQL, n8n identity/config/binary data and Caddy certificates/config.
- На поддерживаемом Ubuntu host системный CA bundle `/etc/ssl/certs/ca-certificates.crt` монтируется в n8n read-only и подключается через `NODE_EXTRA_CA_CERTS`. Это позволяет доверять явно установленным дополнительным CA, не отключая TLS verification; источник и установка дополнительных CA остаются отдельным контролируемым действием.
- Each service explicitly targets `linux/amd64`, matching the only supported MVP architecture and the verified image manifests.
- `docker compose down` preserves volumes. Do not use `down --volumes` outside an explicit destructive procedure.

## Readiness semantics

- PostgreSQL is healthy only after `pg_isready` accepts the configured database/user.
- n8n starts only after PostgreSQL is healthy and becomes healthy only when its own `/healthz` returns a successful HTTP status.
- Caddy starts only after n8n is healthy. Its container health checks the local Caddy admin API; the reverse proxy also actively checks n8n `/healthz`.
- Container health does not prove public DNS, ACME issuance or webhook delivery. `doctor.sh` in `T-0007` owns those external checks.

All services use `restart: unless-stopped`, bounded JSON log rotation and `no-new-privileges`. The stack does not mount the Docker socket and does not use privileged mode.

## Privacy and credentials

- n8n credential values live in its encrypted credential store, not this Compose file or exported workflows.
- Environment access from Code/expressions is blocked, so provider integrations cannot use host environment as an undocumented secret store.
- Anonymous diagnostics and onboarding personalization are disabled.
- Successful, failed and manual executions are retained only within configured pruning limits; execution data may still contain personal information.
- `N8N_RUNNERS_ENABLED` is intentionally absent: it is deprecated in n8n 2.x and no longer required for internal task runners.

## Static validation

Run without creating containers:

```bash
docker compose --env-file tests/fixtures/compose.env config --quiet
docker compose --env-file tests/fixtures/compose.env config --images
```

The rendered config must contain only one of the two approved exact image sets from ADR-0003 and ADR-0012: official registries or the Timeweb proxy with unchanged tags. It must not contain `latest`, PostgreSQL host ports, `privileged`, or Docker socket mounts.

Run the complete automated security assertions with `./tests/security_test.sh`.

`config/Caddyfile` can be validated with the pinned image:

```bash
docker run --rm \
  -e N8N_HOST=n8n.example.test \
  -e ACME_EMAIL=admin@example.test \
  -v "$PWD/config/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2.11.4-alpine caddy validate --config /etc/caddy/Caddyfile
```

Starting the production stack requires the selected hostname to resolve to the VPS, inbound TCP `80/443`, optional UDP `443`, and outbound access to IP-detection, DNS, ACME and provider APIs. For the default path the installer verifies sslip.io resolution before mutation.
