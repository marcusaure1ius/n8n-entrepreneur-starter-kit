#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BACKUP="$ROOT/scripts/backup.sh"
RESTORE="$ROOT/scripts/restore.sh"
COUNT=0
ok(){ COUNT=$((COUNT+1)); printf 'ok %d - %s\n' "$COUNT" "$1"; }
fail(){ printf 'not ok - %s\n' "$1" >&2; exit 1; }

bash -n "$BACKUP" "$RESTORE"
ok "bash syntax"
[[ "$($BACKUP --help)" == *"mode 0600"* ]] || fail "backup help"
[[ "$($RESTORE --help)" == *"safety backup"* ]] || fail "restore help"
ok "Russian safety help"
grep -q 'dockerhub.timeweb.cloud/n8nio/n8n' "$BACKUP" || fail "backup Timeweb source allowlist missing"
grep -q 'dockerhub.timeweb.cloud/n8nio/n8n' "$RESTORE" || fail "restore Timeweb source allowlist missing"
grep -q 'RESTORE_HELPER_IMAGE' "$RESTORE" || fail "restore helper does not follow archive source"
ok "backup and restore preserve the approved image source"

tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
archive="$tmp/sample.tar.gz"
mkdir -p "$tmp/root/payload"
printf 'x' > "$tmp/root/payload/runtime.env"
printf '{}' > "$tmp/root/manifest.json"
(cd "$tmp/root" && sha256sum payload/runtime.env manifest.json > checksums.sha256)
tar -C "$tmp/root" -czf "$archive" manifest.json checksums.sha256 payload
(cd "$tmp" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256")
(cd "$tmp" && sha256sum -c "$(basename "$archive").sha256" >/dev/null) || fail "outer checksum"
ok "outer checksum fixture"

printf 'tamper' >> "$archive"
if (cd "$tmp" && sha256sum -c "$(basename "$archive").sha256" >/dev/null 2>&1); then fail "tamper accepted"; fi
ok "tamper rejection primitive"
printf '1..%d\n' "$COUNT"
