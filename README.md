# Self-hosted Langfuse on Tailscale

A private Docker Compose deployment of Langfuse v4 with:

- Langfuse web and worker services
- PostgreSQL, ClickHouse, Redis, and MinIO
- a Tailscale sidecar that exposes Langfuse only inside the tailnet
- coordinated ClickHouse and MinIO backups to Cloudflare R2
- Taskfile commands for routine operations

No application port is published on the Docker host. Tailscale Serve terminates HTTPS and proxies:

| Tailnet endpoint | Internal target | Purpose |
| --- | --- | --- |
| `https://<tailscale-hostname>.<tailnet>.ts.net` | Langfuse `:3000` | UI, API, and SDK ingestion |
| `https://<tailscale-hostname>.<tailnet>.ts.net:9090` | MinIO `:9000` | Browser media uploads and batch-export downloads |

Tailscale Funnel is explicitly disabled.

## Architecture

```text
Tailnet clients
    |
    +-- HTTPS :443  --> Tailscale sidecar --> Langfuse web (shared network namespace)
    +-- HTTPS :9090 --> Tailscale Serve   --> MinIO S3 API

Langfuse web/worker
    +-- PostgreSQL  (application metadata and configuration)
    +-- ClickHouse  (traces, observations, and scores)
    +-- Redis       (queues/cache)
    +-- MinIO       (events, media, and exports)

Backup script -- ClickHouse native BACKUP + MinIO mirror --> Cloudflare R2
```

The web container shares the Tailscale container's network namespace, following the sidecar pattern used by the related local services. Backing databases are reachable only on the Compose network and do not publish host ports.

## Requirements

- Docker Engine with Docker Compose v2
- [Task](https://taskfile.dev/) (recommended; direct Compose commands also work)
- a Tailscale tailnet with MagicDNS and HTTPS certificates enabled
- a reusable, pre-authorized Tailscale auth key; preferably ephemeral or tagged with an ACL-restricted tag
- an existing Cloudflare R2 bucket and R2 API token with Object Read & Write access
- approximately **4 CPU cores, 16 GiB RAM, and 100 GiB disk** as a practical starting point recommended by Langfuse; size for your ingestion volume

The Docker host must be able to reach Tailscale control servers, the image registries, and the backup S3 endpoint.

## Initial setup

1. Create the environment file:

   ```bash
   task init
   # or: cp .env.example .env
   ```

2. Generate secrets and replace every `CHANGE_ME` value in `.env`:

   ```bash
   openssl rand -base64 32  # NEXTAUTH_SECRET
   openssl rand -base64 32  # SALT
   openssl rand -hex 32     # ENCRYPTION_KEY (exactly 64 hex characters)
   openssl rand -hex 24     # suitable for each service password
   ```

   Keep PostgreSQL, ClickHouse, and Redis passwords URL-safe and alphanumeric. `DATABASE_URL` is assembled from the PostgreSQL values in `compose.yml`.

3. Configure Tailscale:

   - set `TS_HOSTNAME`, for example `langfuse`
   - set `TS_AUTHKEY`
   - replace `example-tailnet.ts.net` in both public URLs with the DNS name shown for your tailnet
   - ensure Tailscale HTTPS is enabled in the admin console
   - allow the tagged node and intended users in your tailnet ACL/grants policy

   `NEXTAUTH_URL` must exactly match the Langfuse URL users and SDKs will access. `LANGFUSE_S3_PUBLIC_ENDPOINT` must use the same Tailscale DNS name with port `9090`.

4. Configure Cloudflare R2. Create the bucket first, then create an R2 API token restricted to that bucket with Object Read & Write access:

   ```dotenv
   AWS_S3_BUCKET_NAME=my-langfuse-backups
   AWS_S3_ENDPOINT_URL=https://ACCOUNT_ID.r2.cloudflarestorage.com
   AWS_S3_ACCESS_KEY_ID=CHANGE_ME
   AWS_S3_SECRET_ACCESS_KEY=CHANGE_ME
   AWS_S3_SIGNATURE_VERSION=v4
   ```

   Do not include the bucket name or a trailing slash in `AWS_S3_ENDPOINT_URL`.

5. Validate and start:

   ```bash
   task validate
   task pull
   task up
   task logs SERVICE=langfuse-web
   ```

   Startup and migrations can take several minutes. Open `NEXTAUTH_URL` once the web service reports that it is ready.

## Environment variables

`.env.example` contains every variable read by this deployment. The important groups are:

| Group | Variables |
| --- | --- |
| Images | `LANGFUSE_VERSION`, `POSTGRES_VERSION`, `CLICKHOUSE_VERSION`, `REDIS_VERSION`, `MINIO_VERSION`, `TAILSCALE_VERSION`, `MINIO_MC_VERSION` |
| Tailscale/public URLs | `TS_HOSTNAME`, `TS_AUTHKEY`, `NEXTAUTH_URL`, `LANGFUSE_S3_PUBLIC_ENDPOINT` |
| Langfuse secrets | `NEXTAUTH_SECRET`, `SALT`, `ENCRYPTION_KEY` |
| PostgreSQL | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` |
| ClickHouse/Redis | `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `REDIS_AUTH` |
| Internal object storage | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, `MINIO_BUCKET`, `MINIO_REGION` |
| Backup storage | `AWS_S3_BUCKET_NAME`, `AWS_S3_ENDPOINT_URL`, `AWS_S3_ACCESS_KEY_ID`, `AWS_S3_SECRET_ACCESS_KEY`, `AWS_S3_SIGNATURE_VERSION` |
| Optional bootstrap | all `LANGFUSE_INIT_*` variables |

The one-time `LANGFUSE_INIT_*` variables are optional. If used, define the whole organization/project/user bootstrap set before the first startup and protect the resulting keys and password.

Do not commit `.env`. Docker named volumes contain sensitive application data and are not encrypted by this stack.

## Common operations

```bash
task                 # list commands
task ps              # service health/status
task logs            # all logs
task logs SERVICE=langfuse-worker
task restart
task pull
task up               # recreate services after image/config changes
task down             # stop without deleting named volumes
```

Direct equivalent:

```bash
docker compose up -d
docker compose logs -f langfuse-web
docker compose down
```

Never run `docker compose down --volumes` unless you intentionally want to delete all local state.

## ClickHouse and MinIO backups to R2

Create and inspect backups:

```bash
task backup
BACKUP_ID=before-upgrade task backup  # optional custom, unique ID
task backups
```

`scripts/backup-r2.sh` performs a coordinated backup:

1. validates the R2 configuration and confirms ClickHouse and MinIO are running
2. records which Langfuse application services are running
3. stops web ingestion, then stops the worker
4. runs ClickHouse's native `BACKUP DATABASE default TO S3(...)` directly to R2
5. mirrors the internal MinIO bucket into the same timestamped R2 backup path
6. restarts only the application services that were running before the backup

The resulting layout is:

```text
r2://<bucket>/<prefix>/<backup-id>/clickhouse/...
r2://<bucket>/<prefix>/<backup-id>/minio/<minio-bucket>/...
```

Each ClickHouse destination must be unique. The generated backup ID is a UTC timestamp; a custom `BACKUP_ID` must not reuse an existing path. If either backup phase fails, the script exits non-zero and still attempts to restart previously running application services.

The `minio-backup` Compose service uses the `tools` profile and the official MinIO Client (`mc`). It does not run with the main stack.

### Schedule backups

Invoke the script through Task from the host's scheduler. Example daily cron entry, adjusted to the actual repository and Task paths:

```cron
15 2 * * * cd /opt/langfuse-ts && /usr/local/bin/task backup >> /var/log/langfuse-backup.log 2>&1
```

Run a backup manually first and verify it with `task backups`. Configure an R2 lifecycle policy for retention, alert on failed scheduler runs, and periodically perform a restore drill on a separate instance.

### Restore planning

No automatic restore task is provided because restoring either data store overwrites live state and requires choosing a coordinated recovery point.

- Restore ClickHouse with its native `RESTORE DATABASE default FROM S3(...)` command into an empty/test database first.
- Restore MinIO by configuring `mc` aliases for R2 and the internal MinIO service, then mirroring the selected backup path back to the bucket.
- Stop Langfuse web and worker services for the entire production restore.
- Verify the selected ClickHouse and MinIO paths share the same backup ID before restoring.

Follow the ClickHouse version-specific restore documentation and test the procedure before relying on it.

### Backup scope: important

This deployment intentionally does **not** back up PostgreSQL. The R2 script covers:

- **ClickHouse:** traces, observations, and scores
- **MinIO:** event payloads, media, and exports

It does not cover:

- **PostgreSQL:** Langfuse application metadata, users, organizations, projects, API keys, and configuration
- **Redis:** queue/cache state
- `.env` secrets or Tailscale state

Consequently, these R2 backups alone are not a complete Langfuse disaster-recovery backup. `task config-backup` archives non-secret deployment files only; store `.env` securely in a password/secret manager.

## Updating

1. Read Langfuse release notes and migration guidance.
2. Run `task backup` and verify the dump.
3. Ensure ClickHouse and MinIO backups are current.
4. Pin or update image versions in `.env`.
5. Run:

   ```bash
   task pull
   task up
   task logs SERVICE=langfuse-web
   ```

Avoid unattended major-version upgrades of PostgreSQL or ClickHouse. Changing only an image major version does not perform the required data migration.

## Troubleshooting

### Tailscale node does not appear

```bash
docker compose logs tailscale
docker compose exec tailscale tailscale status
```

Check that the auth key is valid, pre-authorized, and permitted to use its requested tag. Tailscale state persists in the `tailscale_state` volume; replacing the auth key does not force an already registered node to re-authenticate.

### Langfuse URL or login redirects are wrong

Confirm that `NEXTAUTH_URL` exactly matches `https://<TS_HOSTNAME>.<tailnet>.ts.net`, then recreate the web service:

```bash
docker compose up -d --force-recreate langfuse-web
```

### Media uploads fail

Verify `LANGFUSE_S3_PUBLIC_ENDPOINT`, browse to its `:9090` endpoint from a tailnet client, and inspect both services:

```bash
docker compose logs tailscale minio langfuse-web
```

Port `9090` is the S3 API, not the MinIO administration console. The console is intentionally not exposed.

### A service is unhealthy

```bash
docker compose ps
docker compose logs postgres clickhouse redis minio
```

Check disk space and permissions before deleting or recreating anything.

### R2 backup fails

Confirm the R2 bucket exists, `AWS_S3_ENDPOINT_URL` does not include the bucket name, and the API token permits object reads and writes. Review the failing ClickHouse or MinIO Client output:

```bash
task backup
task backups
```

A failed ClickHouse backup may leave its unique destination occupied. Use a new `BACKUP_ID` after fixing the problem rather than reusing the partial path.

## References

- [Langfuse Docker Compose deployment](https://langfuse.com/self-hosting/deployment/docker-compose)
- [Langfuse self-hosting configuration](https://langfuse.com/self-hosting/configuration)
- [Official Langfuse Compose file](https://github.com/langfuse/langfuse/blob/main/docker-compose.yml)
- [ClickHouse backup and restore](https://clickhouse.com/docs/operations/backup)
- [Cloudflare R2 S3 API](https://developers.cloudflare.com/r2/api/s3/api/)
- [MinIO Client mirror](https://min.io/docs/minio/linux/reference/minio-mc/mc-mirror.html)
- [Tailscale Serve configuration](https://tailscale.com/kb/1242/tailscale-serve)
