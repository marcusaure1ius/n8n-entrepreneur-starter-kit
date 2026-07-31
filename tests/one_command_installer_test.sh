#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILDER="$ROOT/scripts/build-one-command-installer.sh"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
artifact="$temporary/install.sh"
COUNT=0

ok() { COUNT=$((COUNT + 1)); printf 'ok %d - %s\n' "$COUNT" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

bash -n "$BUILDER"
help="$("$BUILDER" --help)"
[[ "$help" == *'curl -fsSL <URL>/install.sh | sh'* ]] || fail 'one-command contract absent from help'
ok 'builder syntax and public contract'

"$BUILDER" --ref HEAD --output "$artifact" >/dev/null
bash -n "$artifact"
grep -q "RELEASE_COMMIT='$(git -C "$ROOT" rev-parse HEAD)'" "$artifact" \
  || fail 'artifact does not pin exact commit'
grep -Eq "ARCHIVE_SHA256='[a-f0-9]{64}'" "$artifact" \
  || fail 'artifact does not embed archive checksum'
grep -q 'installed_commit.*RELEASE_COMMIT' "$artifact" \
  || fail 'artifact does not guard reruns across different releases'
grep -q 'N8N_IMAGE_SOURCE=.*N8N_IMAGE_SOURCE' "$artifact" \
  || fail 'artifact does not propagate explicit image source'
grep -q 'set -- "$@" --yes' "$artifact" \
  || fail 'explicit image source does not authorize safe env migration'
if grep -Eq '(latest|releases/latest)' "$artifact"; then
  fail 'artifact contains floating latest reference'
fi
ok 'artifact pins commit and SHA-256 without latest'

verify_output="$(N8N_BOOTSTRAP_VERIFY_ONLY=1 sh "$artifact")"
[[ "$verify_output" == *'Release '*' проверен по SHA-256'* ]] \
  || fail 'embedded archive verification did not pass'
[[ "$verify_output" == *'Verify-only завершён без изменений системы'* ]] \
  || fail 'verify-only boundary missing'
ok 'embedded release verifies without system mutation'

tampered="$temporary/tampered.sh"
cp "$artifact" "$tampered"
python3 - "$tampered" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_text()
marker = "N8N_KIT_PAYLOAD'\n"
start = data.index(marker) + len(marker)
replacement = "A" if data[start] != "A" else "B"
path.write_text(data[:start] + replacement + data[start + 1:])
PY
set +e
tampered_output="$(N8N_BOOTSTRAP_VERIFY_ONLY=1 sh "$tampered" 2>&1)"
tampered_code=$?
set -e
[[ "$tampered_code" -ne 0 ]] || fail 'tampered payload was accepted'
[[ "$tampered_output" == *'Checksum'* || "$tampered_output" == *'invalid input'* ]] \
  || fail 'tampered payload failure is not explicit'
ok 'tampered embedded release is rejected'

printf '1..%d\n' "$COUNT"
