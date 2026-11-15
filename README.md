# template-rust-service

A starting point for a Rust HTTP service: axum 0.8 on tokio, Postgres through sqlx, an
OpenAPI document generated from the handlers, JSON logs, a trusted-header tenant extractor,
a container image, and a test suite that talks to a real Postgres.

It is a template, not a product: it serves `GET /health` and nothing else. Copy it, rename
it, and write handlers.

## Stack

Rust 1.99.0 (pinned in `rust-toolchain.toml` and the Dockerfile), edition 2024, axum 0.8,
tokio, sqlx 0.9 (runtime queries only — no `query!` macros, so a build needs no database),
utoipa + utoipa-axum, tracing (JSON logs), thiserror, serde.

## Use it

```bash
git clone https://github.com/nonagenticai/template-rust-service
cd template-rust-service
scripts/rename.sh my-service-rs     # crate, binary, image name; idempotent
cargo build --locked
```

Once the rename has run, create your own repository from the result and push it. The name
must be lowercase kebab case (`[a-z][a-z0-9-]*`, ending in a letter or digit) so it is valid
as a crate name, a Docker image and a Kubernetes object name. `scripts/rename.sh` also fixes
the sort order in `Cargo.lock` and formats the tree. The community files
(`CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`) still name this template's
repository in their links — change the owner/name to yours.

## Run it

Configuration is environment only:

| variable | requirement | meaning |
|---|---|---|
| `DATABASE_URL` | required | Postgres URL for the runtime pool |
| `BIND_ADDR` | required | `host:port` to listen on. There is no default port |
| `DATABASE_MIGRATE_URL` | optional | a direct Postgres URL used only for migrations. Set it when `DATABASE_URL` goes through a transaction-pooling proxy such as PgBouncer: sqlx's migrator holds a session-level advisory lock, which is unsafe through transaction pooling. Unset = migrate over `DATABASE_URL` |
| `RUST_LOG` | optional | tracing filter, default `info` |

Migrations in `migrations/*.sql` are embedded in the binary and applied at startup.

```bash
docker run -d --rm -p 127.0.0.1:5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18
export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/postgres
export BIND_ADDR=127.0.0.1:8080
cargo run --locked
curl http://127.0.0.1:8080/health      # {"status":"ok"}
```

`<binary> --print-openapi` writes the OpenAPI document to stdout and exits without reading
the environment or touching a database.

## Layout

| path | what |
|---|---|
| `src/lib.rs` | router and OpenAPI document; register every handler with `routes!` in `api_router()` |
| `src/main.rs` | CLI (`--version`, `--print-openapi`), startup: config, pool, migrations, serve, graceful shutdown |
| `src/routes/` | handlers (`GET /health`) |
| `src/tenant.rs` | `TenantId` extractor for the trusted `X-Tenant-Id` header; `TenantHeader` documents it in OpenAPI |
| `src/config.rs` | environment configuration |
| `src/db.rs` | connection pool and the embedded `MIGRATOR` |
| `src/error.rs` | `AppError`, rendered as `{"detail": "..."}` |
| `src/telemetry.rs` | JSON logging to stdout |
| `migrations/` | SQL migrations (`0001_` prefix ordering); the first one is a placeholder |
| `tests/http.rs` | router tests that need no database |
| `tests/db.rs` | migrations against a real Postgres 18 |
| `parity.toml`, `parity/` | optional contract for comparing a port against a source service |
| `scripts/rename.sh` | replaces the placeholder name |
| `.github/workflows/ci-public.yml` | the CI described below |

## Tests and lint

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

`tests/db.rs` chooses its server in this order: `TEST_DATABASE_URL`, else `DATABASE_URL`
(a URL whose user may `CREATE DATABASE`), else an ephemeral `postgres:18` container started
with docker and removed afterwards. Set `TEST_PG_REGISTRY` (for example
`registry.example.com/library`) to pull that image from a mirror. With no URL and no docker
it fails — it never skips. Each run creates its own database and drops it at the end.

## Container

`Dockerfile` builds the release binary on `debian:12-slim` with the pinned toolchain and
ships it on `debian:12-slim` as uid 65532. Both base images are public, so a fresh clone
builds with no credentials:

```bash
docker build -t my-service .
docker run --rm my-service --version
```

No port is baked in: set `BIND_ADDR` and `DATABASE_URL` at run time. The `HEALTHCHECK`
probes `/health` on the port `BIND_ADDR` names.

## CI

`.github/workflows/ci-public.yml` runs on GitHub-hosted `ubuntu-latest` runners for private and
public repositories alike and needs no repository secrets — the same jobs run in both. It
runs the secret scan, a private-reference scan, `cargo fmt --check`,
`cargo clippy --all-targets --locked -D warnings`, the tests against Postgres 18,
`cargo audit`, a release build smoke (`--version`, `--print-openapi`) and a container build
plus smoke test.

The image is built on every run and pushed to `ghcr.io/<owner>/<repo>` from `main` only when
the repository variable `PUBLISH_IMAGE=true`; unset, it is built and never pushed. Fork pull
requests get a read-only token, so no PR can push.

The workflow is deliberately self-contained. A repository that runs CI on a different runner
pool (for example an internal, self-hosted one) replaces this file with its own.

## Licensing

This repository contains **no licence gate**. There is no gate switch to set: nothing here
reads a licence key, contacts a licence server, or restricts any feature, and the service
runs fully with no licensing configuration. Unset means off — there is nothing to enable.

If a service built from this template adds a licensing gate, document the exact environment
variable, its default, and that unset means off, here.

## License

Apache 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
