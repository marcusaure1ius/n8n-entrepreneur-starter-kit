#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT="$ROOT/dist/install.sh"
REF="HEAD"

usage() {
  cat <<'EOF'
Собрать автономный one-command installer из закоммиченного Git ref.

Использование:
  ./scripts/build-one-command-installer.sh [--ref GIT_REF] [--output PATH]

Артефакт содержит git archive, его точный SHA-256 и bootstrap. После публикации
одного файла по HTTPS пользователь запускает: curl -fsSL <URL>/install.sh | sh
EOF
}

while (($#)); do
  case "$1" in
    --ref)
      (($# >= 2)) || { printf '[FAIL] Для --ref нужен Git ref.\n' >&2; exit 2; }
      REF="$2"
      shift
      ;;
    --output)
      (($# >= 2)) || { printf '[FAIL] Для --output нужен путь.\n' >&2; exit 2; }
      OUTPUT="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '[FAIL] Неизвестный параметр: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

commit="$(git -C "$ROOT" rev-parse --verify "$REF^{commit}")" \
  || { printf '[FAIL] Git ref не является commit: %s\n' "$REF" >&2; exit 2; }
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
archive="$temporary/n8n-entrepreneur-starter-kit.tar.gz"

git -C "$ROOT" archive \
  --format=tar.gz \
  --prefix=n8n-entrepreneur-starter-kit/ \
  --output="$archive" \
  "$commit"
archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"

mkdir -p "$(dirname -- "$OUTPUT")"
cat > "$OUTPUT" <<EOF
#!/bin/sh

set -eu
umask 077

RELEASE_COMMIT='$commit'
ARCHIVE_SHA256='$archive_sha256'
INSTALL_ROOT="\${N8N_KIT_INSTALL_ROOT:-/opt/n8n-entrepreneur-starter-kit}"

fail() {
  printf '[FAIL] %s\n' "\$*" >&2
  exit 1
}

root_run() {
  if [ "\$(id -u)" -eq 0 ]; then
    "\$@"
  else
    command -v sudo >/dev/null 2>&1 || fail 'Нужен sudo или запуск от root.'
    sudo "\$@"
  fi
}

temporary="\$(mktemp -d)" || fail 'Не удалось создать временный каталог.'
trap 'rm -rf -- "\$temporary"' EXIT HUP INT TERM
archive="\$temporary/release.tar.gz"

base64 -d > "\$archive" <<'N8N_KIT_PAYLOAD'
EOF
base64 < "$archive" >> "$OUTPUT"
cat >> "$OUTPUT" <<'EOF'
N8N_KIT_PAYLOAD

actual_sha256="$(sha256sum "$archive" | awk '{print $1}')"
[ "$actual_sha256" = "$ARCHIVE_SHA256" ] \
  || fail 'Checksum автономного release не совпал; установка остановлена.'
printf '[PASS] Release %s проверен по SHA-256.\n' "$RELEASE_COMMIT"

if [ "${N8N_BOOTSTRAP_VERIFY_ONLY:-0}" = 1 ]; then
  printf '[PASS] Verify-only завершён без изменений системы.\n'
  exit 0
fi

if [ -e "$INSTALL_ROOT" ]; then
  [ -x "$INSTALL_ROOT/scripts/install.sh" ] \
    || fail "Каталог $INSTALL_ROOT существует, но не является установкой starter kit."
  [ -f "$INSTALL_ROOT/.release-commit" ] \
    || fail 'Существующая установка создана не one-command installer; используйте документированный migration path.'
  installed_commit="$(cat "$INSTALL_ROOT/.release-commit")"
  [ "$installed_commit" = "$RELEASE_COMMIT" ] \
    || fail "Установлен release $installed_commit, а bootstrap содержит $RELEASE_COMMIT. Используйте update guide; код поверх данных автоматически не заменяется."
  printf '[INFO] Найдена существующая установка; secrets и данные будут сохранены.\n'
else
  mkdir -p "$temporary/extract"
  tar -xzf "$archive" -C "$temporary/extract"
  [ -x "$temporary/extract/n8n-entrepreneur-starter-kit/scripts/install.sh" ] \
    || fail 'Release не содержит executable scripts/install.sh.'
  printf '%s\n' "$RELEASE_COMMIT" \
    > "$temporary/extract/n8n-entrepreneur-starter-kit/.release-commit"
  root_run mkdir -p "$(dirname -- "$INSTALL_ROOT")"
  root_run mv "$temporary/extract/n8n-entrepreneur-starter-kit" "$INSTALL_ROOT"
  printf '[PASS] Release установлен в %s.\n' "$INSTALL_ROOT"
fi

set -- "$INSTALL_ROOT/scripts/install.sh" --non-interactive
if [ -n "${N8N_IMAGE_SOURCE:-}" ]; then
  set -- "$@" --yes
fi

if [ "$(id -u)" -eq 0 ]; then
  env TIMEZONE="${TIMEZONE:-Europe/Moscow}" \
    N8N_IMAGE_SOURCE="${N8N_IMAGE_SOURCE:-}" \
    "$@"
else
  sudo env TIMEZONE="${TIMEZONE:-Europe/Moscow}" \
    N8N_IMAGE_SOURCE="${N8N_IMAGE_SOURCE:-}" \
    "$@"
fi
EOF

chmod 0755 "$OUTPUT"
printf '[PASS] One-command installer: %s\n' "$OUTPUT"
printf '[PASS] Commit: %s\n' "$commit"
printf '[PASS] Embedded archive SHA-256: %s\n' "$archive_sha256"
