#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016,SC2034

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALLER="$ROOT/scripts/install.sh"
TESTS_RUN=0

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

ok() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "ожидалась строка: $needle"
}

bash -n "$INSTALLER"
ok "bash syntax"

help_output="$(bash "$INSTALLER" --help)"
assert_contains "$help_output" "Безопасная установка"
assert_contains "$help_output" "--non-interactive"
ok "русская справка"

# shellcheck source=scripts/install.sh
source "$INSTALLER"

valid_hostname "n8n.example.com" || fail "валидный FQDN отклонён"
if valid_hostname "https://n8n.example.com/path"; then fail "URL принят как FQDN"; fi
valid_email "admin@example.com" || fail "валидный email отклонён"
if valid_email "admin.example.com"; then fail "email без @ принят"; fi
valid_public_ipv4 "8.8.8.8" || fail "публичный IPv4 отклонён"
if valid_public_ipv4 "10.0.0.1"; then fail "private IPv4 принят как public"; fi
valid_secret_value "abcdefghijklmnopqrstuvwxyz123456" || fail "валидный secret отклонён"
if valid_secret_value "short-secret"; then fail "короткий secret принят"; fi
ok "валидация hostname, email и public IPv4"

temporary_root="$(mktemp -d)"
trap 'rm -rf -- "$temporary_root"' EXIT

config_file="$temporary_root/config.env"
printf '%s\n' \
  'N8N_HOST=n8n.example.com' \
  'ACME_EMAIL=admin@example.com' \
  'POSTGRES_PASSWORD=$(touch /tmp/installer-must-not-eval)' > "$config_file"
chmod 0600 "$config_file"
rm -f /tmp/installer-must-not-eval
read_config_file "$config_file"
[[ "$POSTGRES_PASSWORD_VALUE" == '$(touch /tmp/installer-must-not-eval)' ]] || fail "config value изменено"
[[ ! -e /tmp/installer-must-not-eval ]] || fail "config file был выполнен как shell"
ok "config parser не выполняет shell-код"

version_config="$temporary_root/version.env"
printf 'N8N_VERSION=2.29.10\n' > "$version_config"
chmod 0600 "$version_config"
read_config_file "$version_config"
printf 'N8N_VERSION=latest\n' > "$version_config"
set +e
version_output="$(read_config_file "$version_config" 2>&1)"
version_code=$?
set -e
[[ "$version_code" == "$EXIT_USAGE" ]] || fail "неверный N8N_VERSION вернул $version_code"
assert_contains "$version_output" "закреплённой версией 2.29.10"
ok "runtime env принимает только exact n8n pin"

set_image_source timeweb
[[ "$POSTGRES_IMAGE_VALUE" == "dockerhub.timeweb.cloud/library/postgres:17.10-bookworm" ]] \
  || fail "Timeweb PostgreSQL proxy reference неверен"
[[ "$N8N_IMAGE_REPOSITORY_VALUE" == "dockerhub.timeweb.cloud/n8nio/n8n" ]] \
  || fail "Timeweb n8n proxy reference неверен"
[[ "$CADDY_IMAGE_VALUE" == "dockerhub.timeweb.cloud/library/caddy:2.11.4-alpine" ]] \
  || fail "Timeweb Caddy proxy reference неверен"
set_image_source official
set +e
invalid_source_output="$(set_image_source unknown 2>&1)"
invalid_source_code=$?
set -e
[[ "$invalid_source_code" == "$EXIT_USAGE" ]] || fail "неизвестный image source принят"
assert_contains "$invalid_source_output" "official или timeweb"
ok "image source ограничен official и Timeweb proxy с exact tags"

ENV_FILE="$temporary_root/runtime.env"
N8N_HOST_VALUE="n8n.example.com"
ACME_EMAIL_VALUE="admin@example.com"
TIMEZONE_VALUE="Etc/UTC"
POSTGRES_DB_VALUE="n8n"
POSTGRES_USER_VALUE="n8n"
POSTGRES_PASSWORD_VALUE="fixture-postgres-secret"
N8N_ENCRYPTION_KEY_VALUE="fixture-encryption-secret"
EXECUTIONS_DATA_MAX_AGE_VALUE="168"
EXECUTIONS_DATA_PRUNE_MAX_COUNT_VALUE="10000"
DRY_RUN=0
CHECK_ONLY=0
write_output="$(write_env_atomically)"
[[ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")" == "600" ]] || fail "env mode не 600"
[[ "$write_output" != *"fixture-postgres-secret"* ]] || fail "PostgreSQL secret попал в output"
[[ "$write_output" != *"fixture-encryption-secret"* ]] || fail "encryption secret попал в output"
ok "атомарный env mode 0600 без утечки secrets"

NON_INTERACTIVE=1
ASSUME_YES=0
N8N_HOST_VALUE="changed.example.com"
set +e
replace_output="$(confirm_env_replacement 2>&1)"
replace_code=$?
set -e
[[ "$replace_code" == "$EXIT_EXISTING_DATA" ]] || fail "replacement guard вернул $replace_code"
assert_contains "$replace_output" "повторите с --yes"
ASSUME_YES=1
confirm_env_replacement
N8N_HOST_VALUE="n8n.example.com"
ok "non-interactive rerun требует explicit --yes для изменения env"

DRY_RUN=1
CHECK_ONLY=0
side_effect="$temporary_root/side-effect"
run_mutation touch "$side_effect" >/dev/null
[[ ! -e "$side_effect" ]] || fail "dry-run выполнил mutation"
ok "dry-run блокирует mutation"

CONFIGURE_FIREWALL=0
configure_firewall_if_requested \
  || fail "отсутствие firewall opt-in завершило installer с ошибкой"
ok "firewall opt-in необязателен"

doctor_fixture_dir="$temporary_root/doctor-fixture"
mkdir -p "$doctor_fixture_dir"
printf '#!/usr/bin/env bash\nexit 1\n' > "$doctor_fixture_dir/doctor.sh"
chmod +x "$doctor_fixture_dir/doctor.sh"
original_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="$doctor_fixture_dir"
run_post_install_doctor
SCRIPT_DIR="$original_script_dir"
ok "post-install doctor принимает WARN"

fake_docker() {
  printf 'postgres-container\nn8n-container\ncaddy-container\n'
}
original_docker_cmd=("${DOCKER_CMD[@]}")
DOCKER_CMD=(fake_docker)
assert_running_services
DOCKER_CMD=("${original_docker_cmd[@]}")
ok "проверка running services принимает полный список без SIGPIPE"

PULL_ATTEMPTS=0
fake_retry_docker() {
  if [[ "${*: -1}" == "pull" ]]; then
    PULL_ATTEMPTS=$((PULL_ATTEMPTS + 1))
    (( PULL_ATTEMPTS >= 3 ))
    return
  fi
  return 0
}
DOCKER_CMD=(fake_retry_docker)
PULL_RETRY_DELAYS=(0 0)
pull_pinned_images >/dev/null 2>&1 || fail "bounded pull retry не восстановился"
[[ "$PULL_ATTEMPTS" == 3 ]] || fail "ожидалось три pull attempts, получено $PULL_ATTEMPTS"
DOCKER_CMD=("${original_docker_cmd[@]}")
PULL_RETRY_DELAYS=(5 15)
ok "pinned image pull использует максимум три попытки"

NON_INTERACTIVE=1
N8N_HOST_VALUE=""
ACME_EMAIL_VALUE=""
detect_public_ipv4() { printf '203.0.113.10'; }
getent() { printf '203.0.113.10 STREAM n8n-203-0-113-10.sslip.io\n'; }
collect_configuration >/dev/null
[[ "$N8N_HOST_VALUE" == "n8n-203-0-113-10.sslip.io" ]] \
  || fail "non-interactive mode не выбрал бесплатный hostname"
[[ "$HOST_AUTODETECTED" == 1 ]] || fail "autodetected hostname не отмечен"
ok "non-interactive mode автоматически выбирает IP-derived hostname"

NON_INTERACTIVE=0
N8N_HOST_VALUE="n8n.example.com"
ACME_EMAIL_VALUE=""
TIMEZONE_VALUE="Etc/UTC"
collect_configuration <<'EOF' >/dev/null


EOF
[[ "$N8N_HOST_VALUE" == "n8n.example.com" && "$ACME_EMAIL_VALUE" == "" ]] \
  || fail "interactive mode не собрал конфигурацию"
ok "interactive mode не требует ACME email"

ENV_FILE="$temporary_root/missing.env"
DRY_RUN=0
DOCKER_CMD=(docker)
volume_exists() { [[ "$1" == "n8n_data" ]]; }
set +e
guard_output="$(protect_existing_data 2>&1)"
guard_code=$?
set -e
[[ "$guard_code" == "$EXIT_EXISTING_DATA" ]] || fail "existing data guard вернул $guard_code"
assert_contains "$guard_output" "Восстановите исходный env-файл"
ok "persistent volumes без env блокируют генерацию новых secrets"

printf '1..%d\n' "$TESTS_RUN"
