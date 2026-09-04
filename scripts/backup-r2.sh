#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

if [[ ! -f .env ]]; then
  echo "error: ${PROJECT_DIR}/.env does not exist; run 'task init' first" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a
source .env
set +a

required_variables=(
  CLICKHOUSE_USER
  CLICKHOUSE_PASSWORD
  MINIO_ROOT_USER
  MINIO_ROOT_PASSWORD
  MINIO_BUCKET
  AWS_S3_BUCKET_NAME
  AWS_S3_ENDPOINT_URL
  AWS_S3_ACCESS_KEY_ID
  AWS_S3_SECRET_ACCESS_KEY
  AWS_S3_SIGNATURE_VERSION
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "error: ${variable} must be set in .env" >&2
    exit 1
  fi
done

AWS_S3_ENDPOINT_URL="${AWS_S3_ENDPOINT_URL%/}"

if [[ "${AWS_S3_ENDPOINT_URL}" != https://* ]]; then
  echo "error: AWS_S3_ENDPOINT_URL must use HTTPS" >&2
  exit 1
fi

if [[ "${AWS_S3_SIGNATURE_VERSION}" != "v4" ]]; then
  echo "error: AWS_S3_SIGNATURE_VERSION must be v4" >&2
  exit 1
fi

# Values embedded in the ClickHouse S3() expression may not contain quotes or newlines.
for variable in AWS_S3_ENDPOINT_URL AWS_S3_BUCKET_NAME AWS_S3_ACCESS_KEY_ID AWS_S3_SECRET_ACCESS_KEY; do
  value="${!variable}"
  if [[ "${value}" == *"'"* || "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    echo "error: ${variable} contains a character that cannot be used safely" >&2
    exit 1
  fi
done

if ! docker compose ps --status running --services | grep -qx clickhouse; then
  echo "error: ClickHouse is not running; start the stack with 'task up'" >&2
  exit 1
fi
if ! docker compose ps --status running --services | grep -qx minio; then
  echo "error: MinIO is not running; start the stack with 'task up'" >&2
  exit 1
fi

backup_id="${BACKUP_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
backup_root="${backup_id}"
clickhouse_url="${AWS_S3_ENDPOINT_URL}/${AWS_S3_BUCKET_NAME}/${backup_root}/clickhouse"

running_apps=()
for service in langfuse-web langfuse-worker; do
  if docker compose ps --status running --services | grep -qx "${service}"; then
    running_apps+=("${service}")
  fi
done

resume_apps() {
  local status=$?
  if ((${#running_apps[@]})); then
    echo "Restarting previously running Langfuse services..."
    docker compose start "${running_apps[@]}" || true
  fi
  exit "${status}"
}
trap resume_apps EXIT

if ((${#running_apps[@]})); then
  echo "Stopping Langfuse application services for a coordinated backup..."
  # Stop ingestion before stopping the worker.
  if printf '%s\n' "${running_apps[@]}" | grep -qx langfuse-web; then
    docker compose stop langfuse-web
  fi
  if printf '%s\n' "${running_apps[@]}" | grep -qx langfuse-worker; then
    docker compose stop langfuse-worker
  fi
fi

echo "Backing up ClickHouse database 'default' to r2://${AWS_S3_BUCKET_NAME}/${backup_root}/clickhouse ..."
printf "%s\n" "BACKUP DATABASE default TO S3('${clickhouse_url}', '${AWS_S3_ACCESS_KEY_ID}', '${AWS_S3_SECRET_ACCESS_KEY}')" \
  | docker compose exec -T clickhouse clickhouse-client \
      --user "${CLICKHOUSE_USER}" \
      --password "${CLICKHOUSE_PASSWORD}"

echo "Copying MinIO bucket '${MINIO_BUCKET}' to r2://${AWS_S3_BUCKET_NAME}/${backup_root}/minio/${MINIO_BUCKET} ..."
docker compose --profile tools run --rm --no-deps \
  -e BACKUP_ID="${backup_id}" \
  --entrypoint /bin/sh \
  minio-backup -eu -c '
    mc alias set source http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 >/dev/null
    mc alias set r2 "$AWS_S3_ENDPOINT_URL" "$AWS_S3_ACCESS_KEY_ID" "$AWS_S3_SECRET_ACCESS_KEY" --api S3v4 >/dev/null
    destination="r2/$AWS_S3_BUCKET_NAME/$BACKUP_ID/minio/$MINIO_BUCKET"
    mc mirror --overwrite "source/$MINIO_BUCKET" "$destination"
  '

echo "Backup completed: r2://${AWS_S3_BUCKET_NAME}/${backup_root}"
