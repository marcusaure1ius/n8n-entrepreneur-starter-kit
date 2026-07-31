#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="$PROJECT_ROOT/.env"
OUTPUT_DIR="$PROJECT_ROOT/backups"
KEEP=0
TEMP_DIR=""
LOCK_DIR=""
QUIESCED=0
N8N_WAS_RUNNING=0
CADDY_WAS_RUNNING=0
POSTGRES_DB_VALUE="n8n"
POSTGRES_USER_VALUE="n8n"
N8N_VERSION_VALUE="2.29.10"
IMAGE_SOURCE_VALUE="official"
N8N_IMAGE_REPOSITORY_VALUE="docker.n8n.io/n8nio/n8n"
POSTGRES_IMAGE_VALUE="postgres:17.10-bookworm"
CADDY_IMAGE_VALUE="caddy:2.11.4-alpine"
declare -a DOCKER_CMD=(docker)

usage() {
  cat <<'EOF'
Согласованный backup n8n, PostgreSQL, secrets и Caddy state.

Использование:
  ./scripts/backup.sh [--env-file PATH] [--output-dir DIR] [--keep N]

--keep N удаляет только более старые n8n-backup-v1 archives в выбранном
output directory. Default 0 не удаляет ничего.

Archive и sidecar checksum создаются с mode 0600. Во время snapshot n8n и
Caddy кратковременно останавливаются; PostgreSQL остаётся доступен для pg_dump.
EOF
}

log() { printf '[INFO] %s\n' "$*" >&2; }
fatal() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

parse_args() {
  while (($#)); do
    case "$1" in
      --env-file) (($# >= 2)) || fatal "Для --env-file нужен путь."; ENV_FILE="$2"; shift ;;
      --output-dir) (($# >= 2)) || fatal "Для --output-dir нужен путь."; OUTPUT_DIR="$2"; shift ;;
      --keep) (($# >= 2)) || fatal "Для --keep нужно число."; KEEP="$2"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fatal "Неизвестный параметр: $1. Используйте --help." ;;
    esac
    shift
  done
  [[ "$KEEP" =~ ^[0-9]+$ ]] || fatal "--keep должен быть целым неотрицательным числом."
}

read_env_key() {
  local key="$1" file="$2"
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

configure_docker() {
  command -v docker >/dev/null 2>&1 || fatal "Docker не найден."
  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
  elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
  else
    fatal "Docker daemon недоступен."
  fi
  "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1 || fatal "Docker Compose недоступен."
}

compose() { "${DOCKER_CMD[@]}" compose --project-directory "$PROJECT_ROOT" --env-file "$ENV_FILE" "$@"; }

restart_quiesced_services() {
  (( QUIESCED )) || return 0
  if (( N8N_WAS_RUNNING || CADDY_WAS_RUNNING )); then
    log "Возвращаю сервисы в исходное running state."
    if (( CADDY_WAS_RUNNING )); then
      compose up -d --wait --wait-timeout 180 --pull never n8n caddy >/dev/null
    elif (( N8N_WAS_RUNNING )); then
      compose up -d --wait --wait-timeout 180 --pull never n8n >/dev/null
    fi
  fi
  QUIESCED=0
}

cleanup() {
  local code=$?
  trap - EXIT INT TERM
  restart_quiesced_services || printf '[WARN] Не удалось автоматически перезапустить quiesced services.\n' >&2
  [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
  [[ -z "$LOCK_DIR" ]] || rmdir "$LOCK_DIR" 2>/dev/null || true
  exit "$code"
}

archive_volume() {
  local volume="$1" destination="$2"
  "${DOCKER_CMD[@]}" volume inspect "$volume" >/dev/null 2>&1 || fatal "Volume отсутствует: $volume"
  "${DOCKER_CMD[@]}" run --rm --platform linux/amd64 \
    -v "$volume:/source:ro" -v "$destination:/backup" \
    "$CADDY_IMAGE_VALUE" tar -C /source -czf "/backup/$volume.tar.gz" . >/dev/null
}

apply_retention() {
  (( KEEP > 0 )) || return 0
  local -a archives=()
  local remove_count archive
  while IFS= read -r archive; do archives+=("$archive"); done < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'n8n-backup-v1-*.tar.gz' -print | sort)
  remove_count=$((${#archives[@]} - KEEP))
  (( remove_count > 0 )) || return 0
  for ((i=0; i<remove_count; i++)); do
    rm -f -- "${archives[$i]}" "${archives[$i]}.sha256"
  done
  log "Retention удалил $remove_count старых archive(s)."
}

main() {
  local mode timestamp archive partial sidecar_partial created_at
  parse_args "$@"
  [[ -f "$ENV_FILE" ]] || fatal "Env-файл отсутствует: $ENV_FILE"
  mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)"
  [[ "$mode" == 600 ]] || fatal "Env-файл должен иметь mode 0600."
  POSTGRES_DB_VALUE="$(read_env_key POSTGRES_DB "$ENV_FILE")"; POSTGRES_DB_VALUE="${POSTGRES_DB_VALUE:-n8n}"
  POSTGRES_USER_VALUE="$(read_env_key POSTGRES_USER "$ENV_FILE")"; POSTGRES_USER_VALUE="${POSTGRES_USER_VALUE:-n8n}"
  N8N_VERSION_VALUE="$(read_env_key N8N_VERSION "$ENV_FILE")"; N8N_VERSION_VALUE="${N8N_VERSION_VALUE:-2.29.10}"
  [[ "$N8N_VERSION_VALUE" == 2.29.9 || "$N8N_VERSION_VALUE" == 2.29.10 ]] || fatal "N8N_VERSION не входит в approved lifecycle pair."
  IMAGE_SOURCE_VALUE="$(read_env_key N8N_IMAGE_SOURCE "$ENV_FILE")"; IMAGE_SOURCE_VALUE="${IMAGE_SOURCE_VALUE:-official}"
  N8N_IMAGE_REPOSITORY_VALUE="$(read_env_key N8N_IMAGE_REPOSITORY "$ENV_FILE")"; N8N_IMAGE_REPOSITORY_VALUE="${N8N_IMAGE_REPOSITORY_VALUE:-docker.n8n.io/n8nio/n8n}"
  POSTGRES_IMAGE_VALUE="$(read_env_key POSTGRES_IMAGE "$ENV_FILE")"; POSTGRES_IMAGE_VALUE="${POSTGRES_IMAGE_VALUE:-postgres:17.10-bookworm}"
  CADDY_IMAGE_VALUE="$(read_env_key CADDY_IMAGE "$ENV_FILE")"; CADDY_IMAGE_VALUE="${CADDY_IMAGE_VALUE:-caddy:2.11.4-alpine}"
  [[ "$N8N_IMAGE_REPOSITORY_VALUE" == "docker.n8n.io/n8nio/n8n" || "$N8N_IMAGE_REPOSITORY_VALUE" == "dockerhub.timeweb.cloud/n8nio/n8n" ]] \
    || fatal "N8N image repository не входит в approved source set."
  [[ "$POSTGRES_IMAGE_VALUE" == "postgres:17.10-bookworm" || "$POSTGRES_IMAGE_VALUE" == "dockerhub.timeweb.cloud/library/postgres:17.10-bookworm" ]] \
    || fatal "PostgreSQL image не входит в approved source set."
  [[ "$CADDY_IMAGE_VALUE" == "caddy:2.11.4-alpine" || "$CADDY_IMAGE_VALUE" == "dockerhub.timeweb.cloud/library/caddy:2.11.4-alpine" ]] \
    || fatal "Caddy image не входит в approved source set."
  if [[ "$IMAGE_SOURCE_VALUE" == official ]]; then
    [[ "$N8N_IMAGE_REPOSITORY_VALUE" == "docker.n8n.io/n8nio/n8n" \
      && "$POSTGRES_IMAGE_VALUE" == "postgres:17.10-bookworm" \
      && "$CADDY_IMAGE_VALUE" == "caddy:2.11.4-alpine" ]] \
      || fatal "Official backup image set несогласован."
  elif [[ "$IMAGE_SOURCE_VALUE" == timeweb ]]; then
    [[ "$N8N_IMAGE_REPOSITORY_VALUE" == "dockerhub.timeweb.cloud/n8nio/n8n" \
      && "$POSTGRES_IMAGE_VALUE" == "dockerhub.timeweb.cloud/library/postgres:17.10-bookworm" \
      && "$CADDY_IMAGE_VALUE" == "dockerhub.timeweb.cloud/library/caddy:2.11.4-alpine" ]] \
      || fatal "Timeweb backup image set несогласован."
  else
    fatal "N8N_IMAGE_SOURCE не входит в approved source set."
  fi
  configure_docker
  compose config --quiet >/dev/null 2>&1 || fatal "Compose config невалиден."
  [[ -n "$(compose ps --status running -q postgres 2>/dev/null)" ]] || fatal "PostgreSQL должен быть running."

  mkdir -p -- "$OUTPUT_DIR"; chmod 0700 "$OUTPUT_DIR"
  LOCK_DIR="$OUTPUT_DIR/.backup.lock"
  mkdir "$LOCK_DIR" 2>/dev/null || fatal "Другой backup уже выполняется: $LOCK_DIR"
  TEMP_DIR="$(mktemp -d "$OUTPUT_DIR/.backup.tmp.XXXXXX")"
  trap cleanup EXIT INT TERM
  mkdir -p "$TEMP_DIR/payload"

  [[ -n "$(compose ps --status running -q n8n 2>/dev/null)" ]] && N8N_WAS_RUNNING=1
  [[ -n "$(compose ps --status running -q caddy 2>/dev/null)" ]] && CADDY_WAS_RUNNING=1
  if (( N8N_WAS_RUNNING || CADDY_WAS_RUNNING )); then
    log "Quiesce n8n/Caddy для согласованного snapshot."
    compose stop caddy n8n >/dev/null
    QUIESCED=1
  fi

  install -m 0600 "$ENV_FILE" "$TEMP_DIR/payload/runtime.env"
  compose exec -T postgres pg_dump -U "$POSTGRES_USER_VALUE" -d "$POSTGRES_DB_VALUE" \
    --format=custom --no-owner --no-privileges > "$TEMP_DIR/payload/postgres.dump"
  archive_volume n8n_data "$TEMP_DIR/payload"
  archive_volume n8n_caddy_data "$TEMP_DIR/payload"
  archive_volume n8n_caddy_config "$TEMP_DIR/payload"

  created_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  cat > "$TEMP_DIR/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "project": "alfa-ai-course",
  "createdAt": "$created_at",
  "consistency": "quiesced-n8n-logical-postgres",
  "imageSource": "$IMAGE_SOURCE_VALUE",
  "n8nImage": "$N8N_IMAGE_REPOSITORY_VALUE:$N8N_VERSION_VALUE",
  "postgresImage": "$POSTGRES_IMAGE_VALUE",
  "caddyImage": "$CADDY_IMAGE_VALUE"
}
EOF
  (cd "$TEMP_DIR" && find payload -type f -print | sort | xargs sha256sum && sha256sum manifest.json) > "$TEMP_DIR/checksums.sha256"
  restart_quiesced_services

  timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  archive="$OUTPUT_DIR/n8n-backup-v1-$timestamp-$$.tar.gz"
  partial="$archive.partial"
  tar -C "$TEMP_DIR" -czf "$partial" manifest.json checksums.sha256 payload
  chmod 0600 "$partial"
  mv -- "$partial" "$archive"
  sidecar_partial="$archive.sha256.partial"
  (cd "$OUTPUT_DIR" && sha256sum "$(basename "$archive")") > "$sidecar_partial"
  chmod 0600 "$sidecar_partial"
  mv -- "$sidecar_partial" "$archive.sha256"
  apply_retention
  printf 'BACKUP_ARCHIVE=%s\n' "$archive"
}

main "$@"
