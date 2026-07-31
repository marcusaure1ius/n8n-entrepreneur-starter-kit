#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly EXIT_USAGE=2
readonly EXIT_OS=10
readonly EXIT_ARCH=11
readonly EXIT_RESOURCES=12
readonly EXIT_PRIVILEGES=13
readonly EXIT_PORTS=14
readonly EXIT_NETWORK=16
readonly EXIT_DOCKER=20
readonly EXIT_COMPOSE=21
readonly EXIT_ENV=22
readonly EXIT_START=23
readonly EXIT_HEALTH=24
readonly EXIT_EXISTING_DATA=30

readonly DOCKER_VERSION="5:29.6.1-1~ubuntu.24.04~noble"
readonly COMPOSE_VERSION="5.3.1-1~ubuntu.24.04~noble"
readonly EXPECTED_DOCKER_SERVER="29.6.1"
readonly EXPECTED_COMPOSE="5.3.1"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="$PROJECT_ROOT/.env"
CONFIG_FILE=""
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"

NON_INTERACTIVE=0
DRY_RUN=0
CHECK_ONLY=0
ASSUME_YES=0
CONFIGURE_FIREWALL=0
FIREWALL_SSH_PORT=""
WARNING_COUNT=0
HOST_AUTODETECTED=0

N8N_HOST_VALUE=""
ACME_EMAIL_VALUE=""
TIMEZONE_VALUE="Etc/UTC"
POSTGRES_DB_VALUE="n8n"
POSTGRES_USER_VALUE="n8n"
POSTGRES_PASSWORD_VALUE=""
N8N_ENCRYPTION_KEY_VALUE=""
EXECUTIONS_DATA_MAX_AGE_VALUE="168"
EXECUTIONS_DATA_PRUNE_MAX_COUNT_VALUE="10000"
IMAGE_SOURCE_VALUE="official"
POSTGRES_IMAGE_VALUE="postgres:17.10-bookworm"
N8N_IMAGE_REPOSITORY_VALUE="docker.n8n.io/n8nio/n8n"
CADDY_IMAGE_VALUE="caddy:2.11.4-alpine"

declare -a DOCKER_CMD=(docker)
declare -a PULL_RETRY_DELAYS=(5 15)

usage() {
  cat <<'EOF'
Безопасная установка n8n Entrepreneur Starter Kit на Ubuntu 24.04 x86_64.

Использование:
  ./scripts/install.sh [параметры]

Параметры:
  --non-interactive  Не задавать вопросы; обязательные значения взять из
                     переменных окружения, --config или существующего .env.
  --config PATH      Прочитать разрешённые KEY=VALUE из файла PATH.
  --env-file PATH    Записать runtime-конфигурацию в PATH (по умолчанию .env).
  --dry-run          Выполнить проверки и показать план без изменений файлов,
                     пакетов, Docker runtime или sudo timestamp.
  --check-only       Выполнить только preflight-проверки без изменений.
  --yes              Подтвердить замену изменившегося существующего env-файла.
                     Docker volumes и данные этот флаг никогда не удаляет.
  --configure-firewall
                     После установки отдельно применить SSH-safe UFW rules.
                     Без этого флага firewall не меняется.
  --ssh-port PORT    Проверенный SSH port для firewall. В активной SSH-сессии
                     должен совпадать с SSH_CONNECTION.
  -h, --help         Показать эту справку.

Переменные конфигурации:
  N8N_HOST, ACME_EMAIL, TIMEZONE, POSTGRES_DB, POSTGRES_USER,
  POSTGRES_PASSWORD, N8N_ENCRYPTION_KEY, EXECUTIONS_DATA_MAX_AGE,
  EXECUTIONS_DATA_PRUNE_MAX_COUNT. Для VPS Timeweb допустим
  N8N_IMAGE_SOURCE=timeweb; exact image tags сохраняются.

Пример non-interactive dry-run:
  ./scripts/install.sh --non-interactive --dry-run

Если N8N_HOST не задан, installer определит публичный IPv4 и использует
бесплатный адрес n8n-<IPv4-с-дефисами>.sslip.io. Собственный домен можно
передать через N8N_HOST. ACME_EMAIL необязателен.
EOF
}

info() { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
warn() {
  WARNING_COUNT=$((WARNING_COUNT + 1))
  printf '[WARN] %s\n' "$*" >&2
}
fatal() {
  local code="$1"
  shift
  printf '[FAIL] %s\n' "$*" >&2
  exit "$code"
}

on_error() {
  local code="$1"
  local line="$2"
  printf '[FAIL] Неожиданная ошибка (код %s, строка %s). Секреты не выводятся.\n' "$code" "$line" >&2
  exit "$code"
}

quote_command() {
  local item
  for item in "$@"; do
    printf '%q ' "$item"
  done
  printf '\n'
}

run_mutation() {
  if (( DRY_RUN || CHECK_ONLY )); then
    printf '[PLAN] '
    quote_command "$@"
    return 0
  fi
  "$@"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --non-interactive) NON_INTERACTIVE=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --check-only) CHECK_ONLY=1 ;;
      --yes) ASSUME_YES=1 ;;
      --configure-firewall) CONFIGURE_FIREWALL=1 ;;
      --ssh-port)
        (($# >= 2)) || fatal "$EXIT_USAGE" "Для --ssh-port нужен номер порта."
        FIREWALL_SSH_PORT="$2"
        shift
        ;;
      --config)
        (($# >= 2)) || fatal "$EXIT_USAGE" "Для --config нужен путь."
        CONFIG_FILE="$2"
        shift
        ;;
      --env-file)
        (($# >= 2)) || fatal "$EXIT_USAGE" "Для --env-file нужен путь."
        ENV_FILE="$2"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) fatal "$EXIT_USAGE" "Неизвестный параметр: $1. Используйте --help." ;;
    esac
    shift
  done

  if (( DRY_RUN && CHECK_ONLY )); then
    fatal "$EXIT_USAGE" "Выберите только один режим: --dry-run или --check-only."
  fi
  [[ -z "$FIREWALL_SSH_PORT" || "$CONFIGURE_FIREWALL" == 1 ]] \
    || fatal "$EXIT_USAGE" "--ssh-port используется только с --configure-firewall."
  if [[ -n "$FIREWALL_SSH_PORT" ]]; then
    [[ "$FIREWALL_SSH_PORT" =~ ^[0-9]+$ ]] \
      && (( 10#$FIREWALL_SSH_PORT >= 1 && 10#$FIREWALL_SSH_PORT <= 65535 )) \
      || fatal "$EXIT_USAGE" "SSH port должен быть целым числом 1..65535."
  fi
}

strip_optional_quotes() {
  local value="$1"
  if (( ${#value} >= 2 )) && { [[ "$value" == \"*\" && "$value" == *\" ]] || [[ "$value" == \'*\' && "$value" == *\' ]]; }; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

assign_config_value() {
  local key="$1"
  local value="$2"
  value="$(strip_optional_quotes "$value")"
  case "$key" in
    N8N_HOST) N8N_HOST_VALUE="$value" ;;
    ACME_EMAIL) ACME_EMAIL_VALUE="$value" ;;
    TIMEZONE) TIMEZONE_VALUE="$value" ;;
    N8N_VERSION)
      [[ "$value" == "2.29.10" ]] \
        || fatal "$EXIT_USAGE" "N8N_VERSION должен совпадать с закреплённой версией 2.29.10."
      ;;
    POSTGRES_DB) POSTGRES_DB_VALUE="$value" ;;
    POSTGRES_USER) POSTGRES_USER_VALUE="$value" ;;
    POSTGRES_PASSWORD) POSTGRES_PASSWORD_VALUE="$value" ;;
    N8N_ENCRYPTION_KEY) N8N_ENCRYPTION_KEY_VALUE="$value" ;;
    EXECUTIONS_DATA_MAX_AGE) EXECUTIONS_DATA_MAX_AGE_VALUE="$value" ;;
    EXECUTIONS_DATA_PRUNE_MAX_COUNT) EXECUTIONS_DATA_PRUNE_MAX_COUNT_VALUE="$value" ;;
    N8N_IMAGE_SOURCE) set_image_source "$value" ;;
    POSTGRES_IMAGE) POSTGRES_IMAGE_VALUE="$value" ;;
    N8N_IMAGE_REPOSITORY) N8N_IMAGE_REPOSITORY_VALUE="$value" ;;
    CADDY_IMAGE) CADDY_IMAGE_VALUE="$value" ;;
    '') ;;
    *) fatal "$EXIT_USAGE" "Недопустимый ключ конфигурации: $key" ;;
  esac
}

set_image_source() {
  local source="$1"
  case "$source" in
    official)
      IMAGE_SOURCE_VALUE="official"
      POSTGRES_IMAGE_VALUE="postgres:17.10-bookworm"
      N8N_IMAGE_REPOSITORY_VALUE="docker.n8n.io/n8nio/n8n"
      CADDY_IMAGE_VALUE="caddy:2.11.4-alpine"
      ;;
    timeweb)
      IMAGE_SOURCE_VALUE="timeweb"
      POSTGRES_IMAGE_VALUE="dockerhub.timeweb.cloud/library/postgres:17.10-bookworm"
      N8N_IMAGE_REPOSITORY_VALUE="dockerhub.timeweb.cloud/n8nio/n8n"
      CADDY_IMAGE_VALUE="dockerhub.timeweb.cloud/library/caddy:2.11.4-alpine"
      ;;
    *)
      fatal "$EXIT_USAGE" "N8N_IMAGE_SOURCE должен быть official или timeweb."
      ;;
  esac
}

read_config_file() {
  local path="$1"
  local line key value mode
  [[ -f "$path" ]] || fatal "$EXIT_USAGE" "Файл конфигурации не найден: $path"

  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || true)"
  if [[ "$path" != "$ENV_FILE" && -n "$mode" && $((8#$mode & 0077)) -ne 0 ]]; then
    fatal "$EXIT_USAGE" "Файл конфигурации должен быть доступен только владельцу (chmod 600): $path"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || fatal "$EXIT_USAGE" "Ожидалась строка KEY=VALUE в $path."
    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || fatal "$EXIT_USAGE" "Недопустимое имя ключа в $path."
    assign_config_value "$key" "$value"
  done < "$path"
}

apply_process_environment() {
  [[ -n "${N8N_HOST:-}" ]] && N8N_HOST_VALUE="$N8N_HOST"
  [[ -n "${ACME_EMAIL:-}" ]] && ACME_EMAIL_VALUE="$ACME_EMAIL"
  [[ -n "${TIMEZONE:-}" ]] && TIMEZONE_VALUE="$TIMEZONE"
  [[ -n "${POSTGRES_DB:-}" ]] && POSTGRES_DB_VALUE="$POSTGRES_DB"
  [[ -n "${POSTGRES_USER:-}" ]] && POSTGRES_USER_VALUE="$POSTGRES_USER"
  [[ -n "${POSTGRES_PASSWORD:-}" ]] && POSTGRES_PASSWORD_VALUE="$POSTGRES_PASSWORD"
  [[ -n "${N8N_ENCRYPTION_KEY:-}" ]] && N8N_ENCRYPTION_KEY_VALUE="$N8N_ENCRYPTION_KEY"
  [[ -n "${EXECUTIONS_DATA_MAX_AGE:-}" ]] && EXECUTIONS_DATA_MAX_AGE_VALUE="$EXECUTIONS_DATA_MAX_AGE"
  [[ -n "${EXECUTIONS_DATA_PRUNE_MAX_COUNT:-}" ]] && EXECUTIONS_DATA_PRUNE_MAX_COUNT_VALUE="$EXECUTIONS_DATA_PRUNE_MAX_COUNT"
  [[ -n "${N8N_IMAGE_SOURCE:-}" ]] && set_image_source "$N8N_IMAGE_SOURCE"
  return 0
}

prompt_value() {
  local label="$1"
  local default_value="$2"
  local variable_name="$3"
  local answer
  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value"
  else
    printf '%s: ' "$label"
  fi
  IFS= read -r answer || fatal "$EXIT_USAGE" "Не удалось прочитать ввод."
  [[ -n "$answer" ]] || answer="$default_value"
  printf -v "$variable_name" '%s' "$answer"
}

collect_configuration() {
  if [[ -z "$N8N_HOST_VALUE" ]]; then
    configure_default_hostname
  fi

  if (( NON_INTERACTIVE )); then
    return
  fi

  prompt_value "Публичный адрес n8n (Enter — бесплатный sslip.io)" "$N8N_HOST_VALUE" N8N_HOST_VALUE
  prompt_value "Часовой пояс IANA" "$TIMEZONE_VALUE" TIMEZONE_VALUE
}

valid_public_ipv4() {
  local ip="$1" part first second
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r first second part part <<< "$ip"
  while IFS= read -r part; do
    (( 10#$part >= 0 && 10#$part <= 255 )) || return 1
  done < <(tr '.' '\n' <<< "$ip")
  (( 10#$first != 0 && 10#$first != 10 && 10#$first != 127 && 10#$first < 224 )) || return 1
  ! (( 10#$first == 169 && 10#$second == 254 )) || return 1
  ! (( 10#$first == 172 && 10#$second >= 16 && 10#$second <= 31 )) || return 1
  ! (( 10#$first == 192 && 10#$second == 168 )) || return 1
  ! (( 10#$first == 100 && 10#$second >= 64 && 10#$second <= 127 )) || return 1
}

detect_public_ipv4() {
  local endpoint candidate first=""
  for endpoint in https://api.ipify.org https://checkip.amazonaws.com; do
    candidate="$(curl --fail --silent --show-error --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    valid_public_ipv4 "$candidate" || continue
    if [[ -z "$first" ]]; then
      first="$candidate"
    elif [[ "$candidate" == "$first" ]]; then
      printf '%s' "$first"
      return 0
    else
      fatal "$EXIT_NETWORK" "Сервисы определения public IPv4 вернули разные адреса. Задайте N8N_HOST вручную после проверки сети."
    fi
  done
  [[ -n "$first" ]] || fatal "$EXIT_NETWORK" "Не удалось безопасно определить публичный IPv4. Задайте N8N_HOST вручную."
  warn "Публичный IPv4 подтвердил только один внешний сервис; DNS-проверка остаётся обязательной."
  printf '%s' "$first"
}

configure_default_hostname() {
  local public_ip dashed_ip resolved_ip
  command -v curl >/dev/null 2>&1 || fatal "$EXIT_NETWORK" "Для автоматического адреса нужен curl."
  command -v getent >/dev/null 2>&1 || fatal "$EXIT_NETWORK" "Для автоматического адреса нужен getent."
  public_ip="$(detect_public_ipv4)"
  dashed_ip="${public_ip//./-}"
  N8N_HOST_VALUE="n8n-${dashed_ip}.sslip.io"
  resolved_ip="$(getent ahostsv4 "$N8N_HOST_VALUE" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
  [[ "$resolved_ip" == "$public_ip" ]] \
    || fatal "$EXIT_NETWORK" "Бесплатный адрес $N8N_HOST_VALUE не разрешается в public IPv4 $public_ip. Задайте N8N_HOST вручную."
  HOST_AUTODETECTED=1
  pass "Бесплатный HTTPS hostname выбран автоматически: $N8N_HOST_VALUE"
}

valid_hostname() {
  local host="$1"
  [[ ${#host} -le 253 ]] || return 1
  [[ "$host" != *"://"* && "$host" != */* && "$host" == *.* ]] || return 1
  [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

valid_timezone() {
  local timezone="$1"
  [[ "$timezone" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ || "$timezone" == "Etc/UTC" ]]
}

valid_identifier() {
  [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,62}$ ]]
}

valid_secret_value() {
  [[ ${#1} -ge 24 && "$1" =~ ^[A-Za-z0-9._~+/@%=-]+$ ]]
}

validate_configuration() {
  valid_hostname "$N8N_HOST_VALUE" || fatal "$EXIT_USAGE" "N8N_HOST должен быть FQDN без схемы, порта и пути."
  [[ -z "$ACME_EMAIL_VALUE" ]] || valid_email "$ACME_EMAIL_VALUE" \
    || fatal "$EXIT_USAGE" "ACME_EMAIL имеет неверный формат."
  valid_timezone "$TIMEZONE_VALUE" || fatal "$EXIT_USAGE" "TIMEZONE не найден в IANA zoneinfo: $TIMEZONE_VALUE"
  valid_identifier "$POSTGRES_DB_VALUE" || fatal "$EXIT_USAGE" "POSTGRES_DB имеет недопустимый формат."
  valid_identifier "$POSTGRES_USER_VALUE" || fatal "$EXIT_USAGE" "POSTGRES_USER имеет недопустимый формат."
  [[ -z "$POSTGRES_PASSWORD_VALUE" ]] || valid_secret_value "$POSTGRES_PASSWORD_VALUE" \
    || fatal "$EXIT_USAGE" "POSTGRES_PASSWORD должен содержать минимум 24 безопасных dotenv-символа."
  [[ -z "$N8N_ENCRYPTION_KEY_VALUE" ]] || valid_secret_value "$N8N_ENCRYPTION_KEY_VALUE" \
    || fatal "$EXIT_USAGE" "N8N_ENCRYPTION_KEY должен содержать минимум 24 безопасных dotenv-символа."
  [[ "$EXECUTIONS_DATA_MAX_AGE_VALUE" =~ ^[0-9]+$ ]] || fatal "$EXIT_USAGE" "EXECUTIONS_DATA_MAX_AGE должен быть целым числом."
  [[ "$EXECUTIONS_DATA_PRUNE_MAX_COUNT_VALUE" =~ ^[0-9]+$ ]] || fatal "$EXIT_USAGE" "EXECUTIONS_DATA_PRUNE_MAX_COUNT должен быть целым числом."
  case "$IMAGE_SOURCE_VALUE" in
    official)
      [[ "$POSTGRES_IMAGE_VALUE" == "postgres:17.10-bookworm" \
        && "$N8N_IMAGE_REPOSITORY_VALUE" == "docker.n8n.io/n8nio/n8n" \
        && "$CADDY_IMAGE_VALUE" == "caddy:2.11.4-alpine" ]] \
        || fatal "$EXIT_USAGE" "Official image source не совпадает с закреплёнными image references."
      ;;
    timeweb)
      [[ "$POSTGRES_IMAGE_VALUE" == "dockerhub.timeweb.cloud/library/postgres:17.10-bookworm" \
        && "$N8N_IMAGE_REPOSITORY_VALUE" == "dockerhub.timeweb.cloud/n8nio/n8n" \
        && "$CADDY_IMAGE_VALUE" == "dockerhub.timeweb.cloud/library/caddy:2.11.4-alpine" ]] \
        || fatal "$EXIT_USAGE" "Timeweb image source не совпадает с закреплёнными proxy references."
      ;;
    *) fatal "$EXIT_USAGE" "Неизвестный image source: $IMAGE_SOURCE_VALUE" ;;
  esac
  pass "Конфигурация имеет допустимый формат."
}

check_os() {
  local id version
  [[ -r "$OS_RELEASE_FILE" ]] || fatal "$EXIT_OS" "Не найден $OS_RELEASE_FILE. Поддерживается только Ubuntu 24.04."
  id="$(awk -F= '$1 == "ID" {gsub(/^"|"$/, "", $2); print $2; exit}' "$OS_RELEASE_FILE")"
  version="$(awk -F= '$1 == "VERSION_ID" {gsub(/^"|"$/, "", $2); print $2; exit}' "$OS_RELEASE_FILE")"
  [[ "$id" == "ubuntu" && "$version" == "24.04" ]] || fatal "$EXIT_OS" "Поддерживается только Ubuntu 24.04 LTS; обнаружено ${id:-unknown} ${version:-unknown}."
  pass "ОС: Ubuntu 24.04 LTS."
}

check_architecture() {
  local machine="${UNAME_MACHINE_OVERRIDE:-$(uname -m)}"
  [[ "$machine" == "x86_64" || "$machine" == "amd64" ]] || fatal "$EXIT_ARCH" "Поддерживается только x86_64/amd64; обнаружено $machine."
  pass "Архитектура: x86_64."
}

check_resources() {
  local cpu_count mem_kb disk_kb
  cpu_count="${CPU_COUNT_OVERRIDE:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '1')}"
  mem_kb="${MEM_TOTAL_KB_OVERRIDE:-$(awk '/^MemTotal:/ {print $2}' "$MEMINFO_FILE" 2>/dev/null || printf '0')}"
  disk_kb="${DISK_AVAILABLE_KB_OVERRIDE:-$(df -Pk "$PROJECT_ROOT" | awk 'NR==2 {print $4}')}"

  (( cpu_count >= 1 )) || fatal "$EXIT_RESOURCES" "Нужен минимум 1 vCPU."
  (( mem_kb >= 1048576 )) || fatal "$EXIT_RESOURCES" "Нужен минимум 1 GiB RAM."
  (( disk_kb >= 10485760 )) || fatal "$EXIT_RESOURCES" "Нужно минимум 10 GiB свободного места."
  (( cpu_count >= 2 )) || warn "Обнаружен 1 vCPU: подходит только для теста; рекомендуется 2+."
  (( mem_kb >= 2097152 )) || warn "RAM меньше 2 GiB: 1 GiB подходит только для теста."
  (( disk_kb >= 20971520 )) || warn "Свободно меньше 20 GiB; следите за execution data и backup."
  pass "Минимальные ресурсы доступны."
}

check_privileges() {
  if (( EUID == 0 )); then
    pass "Установка запущена с root-правами."
    return
  fi
  command -v sudo >/dev/null 2>&1 || fatal "$EXIT_PRIVILEGES" "Нужен sudo или запуск от root."
  if (( DRY_RUN || CHECK_ONLY )); then
    pass "sudo найден; в безопасном режиме пароль не запрашивается."
    return
  fi
  sudo -v || fatal "$EXIT_PRIVILEGES" "Не удалось подтвердить sudo-доступ."
  pass "sudo-доступ подтверждён."
}

root_command() {
  if (( EUID == 0 )); then
    run_mutation "$@"
  else
    run_mutation sudo "$@"
  fi
}

managed_caddy_running() {
  command -v docker >/dev/null 2>&1 || return 1
  if docker compose --project-directory "$PROJECT_ROOT" ps -q caddy 2>/dev/null | grep -q .; then
    return 0
  fi
  (( DRY_RUN || CHECK_ONLY || EUID == 0 )) && return 1
  sudo -n docker compose --project-directory "$PROJECT_ROOT" ps -q caddy 2>/dev/null | grep -q .
}

check_ports() {
  local listeners
  if ! command -v ss >/dev/null 2>&1; then
    if (( DRY_RUN || CHECK_ONLY )); then
      warn "Команда ss отсутствует; после установки iproute2 порты 80/443 будут проверены."
      return
    fi
    fatal "$EXIT_PORTS" "Команда ss отсутствует после установки зависимостей."
  fi
  listeners="$(ss -ltnH '( sport = :80 or sport = :443 )' 2>/dev/null || true)"
  if [[ -n "$listeners" ]]; then
    if managed_caddy_running; then
      warn "Порты 80/443 заняты Caddy этого проекта; допустимый повторный запуск."
      return
    fi
    fatal "$EXIT_PORTS" "Порты 80 или 443 уже заняты. Освободите их и повторите запуск."
  fi
  pass "Порты 80 и 443 свободны."
}

check_dns() {
  local dns_ip public_ip
  if ! command -v getent >/dev/null 2>&1; then
    warn "getent отсутствует; DNS нельзя проверить до установки системных зависимостей."
    return
  fi
  dns_ip="$(getent ahostsv4 "$N8N_HOST_VALUE" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  if [[ -z "$dns_ip" ]]; then
    (( HOST_AUTODETECTED == 0 )) \
      || fatal "$EXIT_NETWORK" "Автоматический hostname $N8N_HOST_VALUE перестал разрешаться. Повторите позже или задайте N8N_HOST."
    warn "DNS A-запись $N8N_HOST_VALUE пока не разрешается. HTTPS не запустится до распространения DNS."
    return
  fi
  pass "DNS A-запись разрешается в $dns_ip."

  if command -v curl >/dev/null 2>&1; then
    public_ip="$(curl --fail --silent --show-error --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "$public_ip" && "$dns_ip" != "$public_ip" ]]; then
      (( HOST_AUTODETECTED == 0 )) \
        || fatal "$EXIT_NETWORK" "Автоматический hostname разрешается не в public IPv4 этого VPS."
      warn "DNS указывает на $dns_ip, внешний IPv4 этого host — $public_ip. Проверьте NAT/proxy."
    fi
  fi
}

check_network() {
  local registry_status registry_url registry_label
  if ! command -v curl >/dev/null 2>&1; then
    if (( DRY_RUN || CHECK_ONLY )); then
      warn "curl отсутствует; исходящая сеть будет проверена после установки зависимости."
      return
    fi
    fatal "$EXIT_NETWORK" "curl отсутствует после установки зависимостей."
  fi
  curl --fail --silent --show-error --location --max-time 15 --output /dev/null https://download.docker.com/ \
    || fatal "$EXIT_NETWORK" "Нет HTTPS-доступа к download.docker.com."
  if [[ "$IMAGE_SOURCE_VALUE" == timeweb ]]; then
    registry_url="https://dockerhub.timeweb.cloud/v2/"
    registry_label="Timeweb Docker Hub proxy"
  else
    registry_url="https://docker.n8n.io/v2/"
    registry_label="registry n8n"
  fi
  registry_status="$(curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}' "$registry_url" 2>/dev/null || true)"
  [[ "$registry_status" == "200" || "$registry_status" == "401" ]] \
    || fatal "$EXIT_NETWORK" "Нет HTTPS-доступа к $registry_label (HTTP ${registry_status:-none})."
  pass "Исходящий HTTPS к Docker и $registry_label доступен."
}

ensure_base_packages() {
  local missing=0 command_name
  for command_name in curl openssl getent ss; do
    command -v "$command_name" >/dev/null 2>&1 || missing=1
  done
  [[ -e /usr/share/zoneinfo/Etc/UTC ]] || missing=1
  (( missing )) || { pass "Системные зависимости уже установлены."; return; }

  if (( DRY_RUN || CHECK_ONLY )); then
    info "Будут установлены ca-certificates, curl, openssl, libc-bin, iproute2 и tzdata."
    return
  fi
  root_command apt-get update
  root_command apt-get install -y ca-certificates curl openssl libc-bin iproute2 tzdata
  pass "Системные зависимости установлены."
}

check_timezone_available() {
  if [[ -e "/usr/share/zoneinfo/$TIMEZONE_VALUE" ]]; then
    pass "IANA timezone доступен: $TIMEZONE_VALUE."
    return
  fi
  if (( DRY_RUN || CHECK_ONLY )); then
    warn "Timezone $TIMEZONE_VALUE будет проверен после установки tzdata."
    return
  fi
  fatal "$EXIT_USAGE" "TIMEZONE отсутствует в установленной IANA zoneinfo: $TIMEZONE_VALUE"
}

configure_docker_command() {
  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
    return
  fi
  if (( EUID == 0 )); then
    DOCKER_CMD=(docker)
  else
    DOCKER_CMD=(sudo docker)
  fi
  "${DOCKER_CMD[@]}" info >/dev/null 2>&1 || fatal "$EXIT_DOCKER" "Docker установлен, но daemon недоступен. Проверьте systemctl status docker."
}

install_docker() {
  local docker_repo
  info "Docker не найден; будет установлен из официального apt repository с exact pins."
  if (( DRY_RUN || CHECK_ONLY )); then
    info "Docker Engine: $DOCKER_VERSION; Compose plugin: $COMPOSE_VERSION."
    return
  fi

  root_command install -m 0755 -d /etc/apt/keyrings
  if (( EUID == 0 )); then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  else
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.asc
  fi
  docker_repo="Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc"
  if (( EUID == 0 )); then
    printf '%s\n' "$docker_repo" > /etc/apt/sources.list.d/docker.sources
  else
    printf '%s\n' "$docker_repo" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
  fi
  root_command apt-get update

  apt-cache madison docker-ce | awk '{print $3}' | grep -Fxq "$DOCKER_VERSION" \
    || fatal "$EXIT_DOCKER" "Pinned Docker version недоступна в repository: $DOCKER_VERSION"
  apt-cache madison docker-compose-plugin | awk '{print $3}' | grep -Fxq "$COMPOSE_VERSION" \
    || fatal "$EXIT_DOCKER" "Pinned Compose version недоступна в repository: $COMPOSE_VERSION"

  root_command apt-get install -y \
    "docker-ce=$DOCKER_VERSION" \
    "docker-ce-cli=$DOCKER_VERSION" \
    containerd.io \
    "docker-compose-plugin=$COMPOSE_VERSION"
  root_command systemctl enable --now docker
  pass "Pinned Docker Engine и Compose plugin установлены."
}

ensure_docker() {
  local server_version compose_version
  if ! command -v docker >/dev/null 2>&1; then
    install_docker
    (( DRY_RUN || CHECK_ONLY )) && return
  fi

  configure_docker_command
  "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1 || fatal "$EXIT_COMPOSE" "Команда docker compose недоступна."
  server_version="$("${DOCKER_CMD[@]}" version --format '{{.Server.Version}}')"
  compose_version="$("${DOCKER_CMD[@]}" compose version --short)"
  [[ "$server_version" == "$EXPECTED_DOCKER_SERVER" ]] \
    || warn "Существующий Docker $server_version не изменён автоматически; проверенный baseline — $EXPECTED_DOCKER_SERVER."
  [[ "$compose_version" == "$EXPECTED_COMPOSE" ]] \
    || warn "Существующий Compose $compose_version не изменён автоматически; проверенный baseline — $EXPECTED_COMPOSE."
  pass "Docker daemon и Compose доступны."
}

volume_exists() {
  local volume="$1"
  "${DOCKER_CMD[@]}" volume inspect "$volume" >/dev/null 2>&1
}

protect_existing_data() {
  [[ -f "$ENV_FILE" ]] && return
  if command -v docker >/dev/null 2>&1 && (volume_exists n8n_data || volume_exists n8n_postgres_data); then
    fatal "$EXIT_EXISTING_DATA" "Найдены persistent volumes, но $ENV_FILE отсутствует. Восстановите исходный env-файл: новые secrets поверх данных не генерируются."
  fi
  return 0
}

generate_secrets_if_needed() {
  if [[ -z "$POSTGRES_PASSWORD_VALUE" ]]; then
    if (( DRY_RUN || CHECK_ONLY )); then
      POSTGRES_PASSWORD_VALUE="DRY_RUN_POSTGRES_SECRET"
      info "Будет сгенерирован отдельный PostgreSQL password (значение не выводится)."
    else
      POSTGRES_PASSWORD_VALUE="$(openssl rand -hex 32)" || fatal "$EXIT_ENV" "Не удалось сгенерировать PostgreSQL password."
    fi
  fi
  if [[ -z "$N8N_ENCRYPTION_KEY_VALUE" ]]; then
    if (( DRY_RUN || CHECK_ONLY )); then
      N8N_ENCRYPTION_KEY_VALUE="DRY_RUN_N8N_ENCRYPTION_SECRET"
      info "Будет сгенерирован постоянный N8N_ENCRYPTION_KEY (значение не выводится)."
    else
      N8N_ENCRYPTION_KEY_VALUE="$(openssl rand -hex 32)" || fatal "$EXIT_ENV" "Не удалось сгенерировать N8N_ENCRYPTION_KEY."
    fi
  fi
  return 0
}

render_env() {
  cat <<EOF
# Generated by scripts/install.sh. Keep mode 0600 and never commit this file.
N8N_HOST=$N8N_HOST_VALUE
ACME_EMAIL=$ACME_EMAIL_VALUE
TIMEZONE=$TIMEZONE_VALUE
N8N_VERSION=2.29.10
POSTGRES_DB=$POSTGRES_DB_VALUE
POSTGRES_USER=$POSTGRES_USER_VALUE
POSTGRES_PASSWORD=$POSTGRES_PASSWORD_VALUE
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY_VALUE
EXECUTIONS_DATA_MAX_AGE=$EXECUTIONS_DATA_MAX_AGE_VALUE
EXECUTIONS_DATA_PRUNE_MAX_COUNT=$EXECUTIONS_DATA_PRUNE_MAX_COUNT_VALUE
N8N_IMAGE_SOURCE=$IMAGE_SOURCE_VALUE
POSTGRES_IMAGE=$POSTGRES_IMAGE_VALUE
N8N_IMAGE_REPOSITORY=$N8N_IMAGE_REPOSITORY_VALUE
CADDY_IMAGE=$CADDY_IMAGE_VALUE
EOF
}

confirm_env_replacement() {
  local desired_hash current_hash answer
  [[ -f "$ENV_FILE" ]] || return 0
  current_hash="$(sha256sum "$ENV_FILE" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$ENV_FILE" | awk '{print $1}')"
  desired_hash="$(render_env | (sha256sum 2>/dev/null || shasum -a 256) | awk '{print $1}')"
  [[ "$current_hash" == "$desired_hash" ]] && return
  (( ASSUME_YES )) && return
  if (( NON_INTERACTIVE )); then
    fatal "$EXIT_EXISTING_DATA" "Существующий $ENV_FILE отличается. Проверьте изменения и повторите с --yes; volumes не удаляются."
  fi
  printf 'Существующий %s изменится, данные Docker не удаляются. Продолжить? [y/N]: ' "$ENV_FILE"
  IFS= read -r answer || fatal "$EXIT_EXISTING_DATA" "Подтверждение не получено."
  [[ "$answer" == "y" || "$answer" == "Y" ]] || fatal "$EXIT_EXISTING_DATA" "Изменение env-файла отменено."
}

write_env_atomically() {
  local directory temporary
  if (( DRY_RUN || CHECK_ONLY )); then
    info "Будет атомарно записан $ENV_FILE с mode 0600; содержимое и secrets не выводятся."
    return
  fi
  directory="$(dirname -- "$ENV_FILE")"
  [[ -d "$directory" ]] || fatal "$EXIT_ENV" "Каталог env-файла не существует: $directory"
  temporary="$(mktemp "$directory/.env.tmp.XXXXXX")" || fatal "$EXIT_ENV" "Не удалось создать временный env-файл."
  trap 'rm -f -- "${temporary:-}"' RETURN
  render_env > "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$ENV_FILE"
  trap - RETURN
  [[ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")" == "600" ]] \
    || fatal "$EXIT_ENV" "Не удалось установить mode 0600 для $ENV_FILE."
  pass "Runtime env-файл записан с mode 0600; secrets скрыты."
}

validate_compose() {
  if (( DRY_RUN || CHECK_ONLY )); then
    info "Будет выполнен docker compose config --quiet без печати resolved secrets."
    return
  fi
  compose_project config --quiet \
    || fatal "$EXIT_COMPOSE" "Compose-конфигурация невалидна."
  pass "Compose-конфигурация валидна."
}

compose_project() {
  "${DOCKER_CMD[@]}" compose --project-directory "$PROJECT_ROOT" --env-file "$ENV_FILE" "$@"
}

pull_pinned_images() {
  local attempt=1
  local max_attempts=$(( ${#PULL_RETRY_DELAYS[@]} + 1 ))
  local delay

  while (( attempt <= max_attempts )); do
    info "Скачивание pinned images: попытка $attempt из $max_attempts; source=$IMAGE_SOURCE_VALUE."
    if compose_project pull; then
      pass "Pinned images скачаны."
      return 0
    fi
    (( attempt < max_attempts )) || return 1
    delay="${PULL_RETRY_DELAYS[$((attempt - 1))]}"
    warn "Скачивание не удалось; повтор через ${delay} секунд. Exact tags не изменяются."
    (( delay == 0 )) || sleep "$delay"
    attempt=$((attempt + 1))
  done
  return 1
}

run_post_install_doctor() {
  local doctor_code

  if "$SCRIPT_DIR/doctor.sh" --env-file "$ENV_FILE" --local-only; then
    doctor_code=0
  else
    doctor_code=$?
  fi
  (( doctor_code < 2 )) || fatal "$EXIT_HEALTH" "Post-install doctor обнаружил FAIL. Запустите scripts/doctor.sh --local-only."
}

assert_running_services() {
  local running_ids

  running_ids="$(compose_project ps --status running -q)" \
    || fatal "$EXIT_HEALTH" "Не удалось получить список работающих сервисов."
  [[ -n "$running_ids" ]] || fatal "$EXIT_HEALTH" "После запуска нет работающих сервисов."
}

start_stack() {
  if (( DRY_RUN || CHECK_ONLY )); then
    info "Будут выполнены pinned image pull и docker compose up -d --wait; volumes не удаляются."
    return
  fi
  pull_pinned_images \
    || fatal "$EXIT_START" "Не удалось скачать pinned images после ограниченных повторов. Для Timeweb используйте N8N_IMAGE_SOURCE=timeweb по Quick Start."
  compose_project up -d --wait --wait-timeout 300 \
    || fatal "$EXIT_HEALTH" "Сервисы не достигли healthy за 300 секунд. Запустите docker compose ps и logs."
  assert_running_services
  run_post_install_doctor
  pass "Compose stack запущен и достиг healthy."
}

configure_firewall_if_requested() {
  local -a firewall_args
  (( CONFIGURE_FIREWALL )) || return 0
  firewall_args=("$SCRIPT_DIR/firewall.sh")
  if (( DRY_RUN )); then
    firewall_args+=(--preview)
  else
    firewall_args+=(--apply)
  fi
  [[ -z "$FIREWALL_SSH_PORT" ]] || firewall_args+=(--ssh-port "$FIREWALL_SSH_PORT")
  (( ASSUME_YES && ! DRY_RUN )) && firewall_args+=(--yes)
  "${firewall_args[@]}"
}

print_summary() {
  if (( CHECK_ONLY )); then
    info "Preflight завершён; изменений не выполнено. Предупреждений: $WARNING_COUNT."
  elif (( DRY_RUN )); then
    info "Dry-run завершён; файлы, packages, sudo timestamp и Docker runtime не изменены. Предупреждений: $WARNING_COUNT."
  else
    cat <<EOF

Установка завершена.
  URL: https://$N8N_HOST_VALUE/
  Конфигурация: $ENV_FILE (mode 0600)
  Данные: named Docker volumes n8n_data, n8n_postgres_data и n8n_caddy_data
  Статус: ${DOCKER_CMD[*]} compose --project-directory $PROJECT_ROOT ps

Не публикуйте .env и не используйте docker compose down --volumes.
EOF
  fi
}

main() {
  local env_n8n_host="${N8N_HOST:-}"
  local env_acme_email="${ACME_EMAIL:-}"
  local env_timezone="${TIMEZONE:-}"
  local env_postgres_db="${POSTGRES_DB:-}"
  local env_postgres_user="${POSTGRES_USER:-}"
  local env_postgres_password="${POSTGRES_PASSWORD:-}"
  local env_encryption_key="${N8N_ENCRYPTION_KEY:-}"
  local env_max_age="${EXECUTIONS_DATA_MAX_AGE:-}"
  local env_max_count="${EXECUTIONS_DATA_PRUNE_MAX_COUNT:-}"
  local env_image_source="${N8N_IMAGE_SOURCE:-}"

  trap 'on_error $? $LINENO' ERR
  parse_args "$@"

  if [[ -f "$ENV_FILE" ]]; then
    read_config_file "$ENV_FILE"
    pass "Существующий env-файл найден; secrets будут сохранены, если явно не заданы другие значения."
  fi
  [[ -z "$CONFIG_FILE" ]] || read_config_file "$CONFIG_FILE"

  N8N_HOST="$env_n8n_host" ACME_EMAIL="$env_acme_email" TIMEZONE="$env_timezone" \
    POSTGRES_DB="$env_postgres_db" POSTGRES_USER="$env_postgres_user" \
    POSTGRES_PASSWORD="$env_postgres_password" N8N_ENCRYPTION_KEY="$env_encryption_key" \
    EXECUTIONS_DATA_MAX_AGE="$env_max_age" EXECUTIONS_DATA_PRUNE_MAX_COUNT="$env_max_count" \
    N8N_IMAGE_SOURCE="$env_image_source" \
    apply_process_environment

  collect_configuration
  validate_configuration
  check_os
  check_architecture
  check_resources
  check_privileges
  ensure_base_packages
  check_timezone_available
  check_ports
  check_dns
  check_network
  ensure_docker
  protect_existing_data

  if (( CHECK_ONLY )); then
    print_summary
    return
  fi

  generate_secrets_if_needed
  confirm_env_replacement
  write_env_atomically
  validate_compose
  start_stack
  configure_firewall_if_requested
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
