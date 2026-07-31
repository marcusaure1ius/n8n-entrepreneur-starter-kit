#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="$PROJECT_ROOT/.env"
STATE_FILE="$PROJECT_ROOT/.lifecycle/update-state.env"
ASSUME_YES=0

usage() {
  cat <<'EOF'
Restore-based rollback утверждённой n8n lifecycle pair.

Использование:
  ./scripts/rollback.sh [--env-file PATH] [--state-file PATH] [--yes]

Rollback принимает только metadata для 2.29.9 <- 2.29.10 и восстанавливает
полный pre-update backup. Image-only downgrade запрещён.
EOF
}

fatal() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
read_key() { awk -F= -v wanted="$1" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$2"; }

parse_args() {
  while (($#)); do
    case "$1" in
      --env-file) (($# >= 2)) || fatal "Для --env-file нужен путь."; ENV_FILE="$2"; shift ;;
      --state-file) (($# >= 2)) || fatal "Для --state-file нужен путь."; STATE_FILE="$2"; shift ;;
      --yes) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) fatal "Неизвестный параметр: $1. Используйте --help." ;;
    esac
    shift
  done
}

write_state() {
  local status="$1" current="$2" previous="$3" archive="$4" forward="$5" temporary directory
  directory="$(dirname "$STATE_FILE")"; mkdir -p "$directory"; chmod 0700 "$directory"
  temporary="$(mktemp "$directory/.update-state.tmp.XXXXXX")"
  printf 'STATUS=%s\nCURRENT_VERSION=%s\nPREVIOUS_VERSION=%s\nBACKUP_ARCHIVE=%s\nFORWARD_BACKUP_ARCHIVE=%s\nUPDATED_AT=%s\n' \
    "$status" "$current" "$previous" "$archive" "$forward" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$temporary"
  chmod 0600 "$temporary"; mv -f -- "$temporary" "$STATE_FILE"
}

main() {
  local status current previous archive env_current n8n_repository answer output safety safety_dir doctor_code
  parse_args "$@"
  [[ -f "$ENV_FILE" ]] || fatal "Env-файл отсутствует: $ENV_FILE"
  [[ -f "$STATE_FILE" ]] || fatal "Lifecycle metadata отсутствует: $STATE_FILE"
  status="$(read_key STATUS "$STATE_FILE")"
  current="$(read_key CURRENT_VERSION "$STATE_FILE")"
  previous="$(read_key PREVIOUS_VERSION "$STATE_FILE")"
  archive="$(read_key BACKUP_ARCHIVE "$STATE_FILE")"
  [[ "$status" == updated || "$status" == update_pending ]] || fatal "Metadata status не разрешает rollback: $status"
  [[ "$current" == 2.29.10 && "$previous" == 2.29.9 ]] || fatal "Rollback разрешён только для 2.29.10 -> 2.29.9."
  env_current="$(read_key N8N_VERSION "$ENV_FILE")"; env_current="${env_current:-2.29.10}"
  [[ "$env_current" == 2.29.10 ]] || fatal "Current env version не совпадает с metadata."
  [[ -f "$archive" && -f "$archive.sha256" ]] || fatal "Pre-update backup или checksum отсутствует."
  n8n_repository="$(read_key N8N_IMAGE_REPOSITORY "$ENV_FILE")"; n8n_repository="${n8n_repository:-docker.n8n.io/n8nio/n8n}"
  [[ "$n8n_repository" == docker.n8n.io/n8nio/n8n || "$n8n_repository" == dockerhub.timeweb.cloud/n8nio/n8n ]] \
    || fatal "N8N image repository не входит в approved source set."
  docker image inspect "$n8n_repository:2.29.9" >/dev/null 2>&1 || fatal "Rollback image 2.29.9 отсутствует локально; не запускайте unsafe downgrade."
  if (( ! ASSUME_YES )); then
    printf 'Восстановить полный pre-update backup и n8n 2.29.9? [y/N]: '
    IFS= read -r answer || fatal "Подтверждение не получено."
    [[ "$answer" == y || "$answer" == Y ]] || fatal "Rollback отменён."
  fi
  safety_dir="$(dirname "$STATE_FILE")/pre-rollback"
  output="$("$SCRIPT_DIR/restore.sh" "$archive" --env-file "$ENV_FILE" --safety-backup-dir "$safety_dir" --yes)"
  safety="$(printf '%s\n' "$output" | awk -F= '$1 == "SAFETY_ARCHIVE" {print $2; exit}')"
  [[ "$(read_key N8N_VERSION "$ENV_FILE")" == 2.29.9 ]] || fatal "Restore не вернул approved previous version."
  set +e; "$SCRIPT_DIR/doctor.sh" --env-file "$ENV_FILE" --local-only >/dev/null; doctor_code=$?; set -e
  (( doctor_code < 2 )) || fatal "Post-rollback doctor обнаружил FAIL."
  write_state rolled_back 2.29.9 2.29.10 "$archive" "$safety"
  printf 'ROLLED_BACK_VERSION=2.29.9\nPREVIOUS_VERSION=2.29.10\nRESTORED_ARCHIVE=%s\n' "$archive"
  [[ -z "$safety" ]] || printf 'FORWARD_BACKUP_ARCHIVE=%s\n' "$safety"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
