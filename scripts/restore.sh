#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="$PROJECT_ROOT/.env"
SAFETY_DIR="$PROJECT_ROOT/backups/pre-restore"
ARCHIVE=""
ASSUME_YES=0
ROLLBACK_MODE=0
TEMP_DIR=""
RESTORE_HELPER_IMAGE="caddy:2.11.4-alpine"
MUTATION_STARTED=0
SAFETY_ARCHIVE=""
EXISTING_STATE=0
POSTGRES_DB_VALUE="n8n"
POSTGRES_USER_VALUE="n8n"
declare -a DOCKER_CMD=(docker)

usage() {
  cat <<'EOF'
Проверяемое восстановление полного n8n recovery state.

Использование:
  ./scripts/restore.sh ARCHIVE [--env-file PATH] [--safety-backup-dir DIR] [--yes]

До любых изменений проверяются outer checksum, archive paths, schema, image
compatibility и payload checksums. Existing state требует подтверждение и
обязательный pre-restore safety backup. Secrets не выводятся.
EOF
}

log() { printf '[INFO] %s\n' "$*" >&2; }
fatal() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

parse_args() {
  (($# >= 1)) || { usage >&2; exit 2; }
  if [[ "$1" == -h || "$1" == --help ]]; then usage; exit 0; fi
  ARCHIVE="$1"; shift
  while (($#)); do
    case "$1" in
      --env-file) (($# >= 2)) || fatal "Для --env-file нужен путь."; ENV_FILE="$2"; shift ;;
      --safety-backup-dir) (($# >= 2)) || fatal "Для --safety-backup-dir нужен путь."; SAFETY_DIR="$2"; shift ;;
      --yes) ASSUME_YES=1 ;;
      --rollback-mode) ROLLBACK_MODE=1; ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) fatal "Неизвестный параметр: $1. Используйте --help." ;;
    esac
    shift
  done
}

read_env_key() { awk -F= -v wanted="$1" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$2"; }

configure_docker() {
  command -v docker >/dev/null 2>&1 || fatal "Docker не найден."
  if docker info >/dev/null 2>&1; then DOCKER_CMD=(docker)
  elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then DOCKER_CMD=(sudo docker)
  else fatal "Docker daemon недоступен."; fi
  "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1 || fatal "Docker Compose недоступен."
}

compose() { "${DOCKER_CMD[@]}" compose --project-directory "$PROJECT_ROOT" --env-file "$ENV_FILE" "$@"; }

existing_volume() { "${DOCKER_CMD[@]}" volume inspect "$1" >/dev/null 2>&1; }

verify_archive() {
  local sidecar="$ARCHIVE.sha256" entry type schema project n8n_image postgres_image caddy_image sidecar_name sidecar_lines
  [[ -f "$ARCHIVE" ]] || fatal "Archive не найден: $ARCHIVE"
  [[ -f "$sidecar" ]] || fatal "Обязательный outer checksum отсутствует: $sidecar"
  sidecar_lines="$(wc -l < "$sidecar" | tr -d ' ')"
  sidecar_name="$(awk 'NR == 1 {sub(/^\*/, "", $2); print $2}' "$sidecar")"
  [[ "$sidecar_lines" == 1 && "$sidecar_name" == "$(basename "$ARCHIVE")" ]] || fatal "Outer checksum содержит неожиданный filename."
  (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$sidecar")" >/dev/null) || fatal "Outer archive checksum mismatch."
  while IFS= read -r entry; do
    [[ "$entry" != /* && "$entry" != .. && "$entry" != ../* && "$entry" != */../* && "$entry" != */.. ]] || fatal "Archive содержит небезопасный path."
  done < <(tar -tzf "$ARCHIVE")
  while IFS= read -r type; do
    [[ "$type" == - || "$type" == d ]] || fatal "Archive содержит symlink или special entry."
  done < <(tar -tvzf "$ARCHIVE" | cut -c1)
  TEMP_DIR="$(mktemp -d)"
  tar -C "$TEMP_DIR" -xzf "$ARCHIVE"
  for entry in manifest.json checksums.sha256 payload/runtime.env payload/postgres.dump payload/n8n_data.tar.gz payload/n8n_caddy_data.tar.gz payload/n8n_caddy_config.tar.gz; do
    [[ -f "$TEMP_DIR/$entry" ]] || fatal "Archive не содержит $entry"
  done
  (cd "$TEMP_DIR" && sha256sum -c checksums.sha256 >/dev/null) || fatal "Payload checksum mismatch."
  schema="$(sed -n 's/.*"schemaVersion": \([0-9][0-9]*\).*/\1/p' "$TEMP_DIR/manifest.json")"
  project="$(sed -n 's/.*"project": "\([^"]*\)".*/\1/p' "$TEMP_DIR/manifest.json")"
  n8n_image="$(sed -n 's/.*"n8nImage": "\([^"]*\)".*/\1/p' "$TEMP_DIR/manifest.json")"
  postgres_image="$(sed -n 's/.*"postgresImage": "\([^"]*\)".*/\1/p' "$TEMP_DIR/manifest.json")"
  caddy_image="$(sed -n 's/.*"caddyImage": "\([^"]*\)".*/\1/p' "$TEMP_DIR/manifest.json")"
  [[ "$schema" == 1 && "$project" == alfa-ai-course ]] || fatal "Unsupported backup schema/project."
  if [[ ( "$n8n_image" == docker.n8n.io/n8nio/n8n:2.29.9 || "$n8n_image" == docker.n8n.io/n8nio/n8n:2.29.10 ) \
    && "$postgres_image" == postgres:17.10-bookworm \
    && "$caddy_image" == caddy:2.11.4-alpine ]]; then
    RESTORE_HELPER_IMAGE="$caddy_image"
  elif [[ ( "$n8n_image" == dockerhub.timeweb.cloud/n8nio/n8n:2.29.9 || "$n8n_image" == dockerhub.timeweb.cloud/n8nio/n8n:2.29.10 ) \
    && "$postgres_image" == dockerhub.timeweb.cloud/library/postgres:17.10-bookworm \
    && "$caddy_image" == dockerhub.timeweb.cloud/library/caddy:2.11.4-alpine ]]; then
    RESTORE_HELPER_IMAGE="$caddy_image"
  else
    fatal "Backup image compatibility mismatch."
  fi
  for entry in n8n_data.tar.gz n8n_caddy_data.tar.gz n8n_caddy_config.tar.gz; do
    while IFS= read -r type; do
      [[ "$type" == - || "$type" == d ]] || fatal "$entry содержит symlink или special entry."
    done < <(tar -tvzf "$TEMP_DIR/payload/$entry" | cut -c1)
    while IFS= read -r type; do
      [[ "$type" != /* && "$type" != .. && "$type" != ../* && "$type" != */../* && "$type" != */.. ]] || fatal "$entry содержит небезопасный path."
    done < <(tar -tzf "$TEMP_DIR/payload/$entry")
  done
  log "Archive schema, compatibility и checksums подтверждены."
}

restore_volume() {
  local volume="$1" archive_name="$2"
  "${DOCKER_CMD[@]}" volume create "$volume" >/dev/null
  "${DOCKER_CMD[@]}" run --rm --platform linux/amd64 \
    -v "$volume:/target" -v "$TEMP_DIR/payload:/backup:ro" "$RESTORE_HELPER_IMAGE" \
    sh -eu -c "rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null || true; tar -C /target -xzf /backup/$archive_name" >/dev/null
}

perform_restore() {
  local archived_env="$TEMP_DIR/payload/runtime.env"
  MUTATION_STARTED=1
  if (( EXISTING_STATE )); then compose down --remove-orphans >/dev/null; fi
  install -m 0600 "$archived_env" "$ENV_FILE.tmp"
  mv -f -- "$ENV_FILE.tmp" "$ENV_FILE"
  POSTGRES_DB_VALUE="$(read_env_key POSTGRES_DB "$ENV_FILE")"; POSTGRES_DB_VALUE="${POSTGRES_DB_VALUE:-n8n}"
  POSTGRES_USER_VALUE="$(read_env_key POSTGRES_USER "$ENV_FILE")"; POSTGRES_USER_VALUE="${POSTGRES_USER_VALUE:-n8n}"
  compose config --quiet >/dev/null 2>&1 || fatal "Restored env несовместим с Compose."
  restore_volume n8n_data n8n_data.tar.gz
  restore_volume n8n_caddy_data n8n_caddy_data.tar.gz
  restore_volume n8n_caddy_config n8n_caddy_config.tar.gz
  compose up -d --wait --wait-timeout 180 --pull never postgres >/dev/null
  compose exec -T postgres dropdb --if-exists --force --maintenance-db=postgres -U "$POSTGRES_USER_VALUE" "$POSTGRES_DB_VALUE" >/dev/null
  compose exec -T postgres createdb --maintenance-db=postgres -U "$POSTGRES_USER_VALUE" "$POSTGRES_DB_VALUE" >/dev/null
  compose exec -T postgres pg_restore -U "$POSTGRES_USER_VALUE" -d "$POSTGRES_DB_VALUE" --no-owner --no-privileges < "$TEMP_DIR/payload/postgres.dump"
  compose up -d --wait --wait-timeout 300 --pull never >/dev/null
  set +e
  "$SCRIPT_DIR/doctor.sh" --env-file "$ENV_FILE" --local-only >/dev/null
  local doctor_code=$?
  set -e
  (( doctor_code < 2 )) || fatal "Post-restore doctor обнаружил FAIL."
  MUTATION_STARTED=0
}

on_exit() {
  local code=$?
  trap - EXIT
  if (( code != 0 && MUTATION_STARTED )); then
    if [[ -n "$SAFETY_ARCHIVE" && $ROLLBACK_MODE -eq 0 ]]; then
      printf '[WARN] Restore failed; запускаю automatic rollback из safety backup.\n' >&2
      "$0" "$SAFETY_ARCHIVE" --env-file "$ENV_FILE" --safety-backup-dir "$SAFETY_DIR" --yes --rollback-mode \
        || printf '[FAIL] Automatic rollback failed; используйте safety archive вручную: %s\n' "$SAFETY_ARCHIVE" >&2
    else
      compose down --remove-orphans >/dev/null 2>&1 || true
    fi
  fi
  [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
  exit "$code"
}

main() {
  local answer backup_output old_db old_user new_db new_user
  parse_args "$@"
  configure_docker
  trap on_exit EXIT
  verify_archive
  [[ -f "$ENV_FILE" ]] && EXISTING_STATE=1
  for volume in n8n_postgres_data n8n_data n8n_caddy_data n8n_caddy_config; do existing_volume "$volume" && EXISTING_STATE=1; done

  if (( EXISTING_STATE && ROLLBACK_MODE == 0 )); then
    [[ -f "$ENV_FILE" ]] || fatal "Existing volumes найдены без env-файла; восстановите original env перед overwrite."
    old_db="$(read_env_key POSTGRES_DB "$ENV_FILE")"; old_db="${old_db:-n8n}"
    old_user="$(read_env_key POSTGRES_USER "$ENV_FILE")"; old_user="${old_user:-n8n}"
    new_db="$(read_env_key POSTGRES_DB "$TEMP_DIR/payload/runtime.env")"; new_db="${new_db:-n8n}"
    new_user="$(read_env_key POSTGRES_USER "$TEMP_DIR/payload/runtime.env")"; new_user="${new_user:-n8n}"
    [[ "$old_db" == "$new_db" && "$old_user" == "$new_user" ]] || fatal "Cross-identity restore (database/user change) не поддерживается."
    if (( ! ASSUME_YES )); then
      printf 'Restore перезапишет database и volumes после safety backup. Продолжить? [y/N]: '
      IFS= read -r answer || fatal "Подтверждение не получено."
      [[ "$answer" == y || "$answer" == Y ]] || fatal "Restore отменён."
    fi
    mkdir -p "$SAFETY_DIR"; chmod 0700 "$SAFETY_DIR"
    backup_output="$("$SCRIPT_DIR/backup.sh" --env-file "$ENV_FILE" --output-dir "$SAFETY_DIR")"
    SAFETY_ARCHIVE="$(printf '%s\n' "$backup_output" | awk -F= '$1 == "BACKUP_ARCHIVE" {print $2; exit}')"
    [[ -n "$SAFETY_ARCHIVE" && -f "$SAFETY_ARCHIVE" ]] || fatal "Pre-restore safety backup не создан."
    log "Safety backup создан до overwrite."
  fi
  perform_restore
  printf 'RESTORED_ARCHIVE=%s\n' "$ARCHIVE"
  [[ -z "$SAFETY_ARCHIVE" ]] || printf 'SAFETY_ARCHIVE=%s\n' "$SAFETY_ARCHIVE"
}

main "$@"
