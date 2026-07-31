# Установка

Публичный автономный `install.sh` устанавливает базовый профиль n8n Entrepreneur Starter Kit на чистую Ubuntu 24.04 LTS x86_64. Его пользовательский интерфейс — одна команда `curl -fsSL <stable HTTPS URL>/install.sh | sh`. Внутри exact release вызывается `scripts/install.sh`.

Если VPS ещё не подготовлен, начните с [Quick Start](quick-start.md), [Timeweb Cloud](timeweb-cloud.md) либо [Yandex Cloud](yandex-cloud.md). Собственный домен — [необязательный advanced path](domain-and-dns.md).

## До запуска

Подготовьте:

- VPS с Ubuntu 24.04 LTS x86_64, минимум 1 vCPU, 1 GiB RAM и 10 GiB свободного места;
- закреплённый публичный IPv4 VPS;
- SSH-пользователя с `sudo`;
- свободные TCP-порты 80 и 443;
- исходящий HTTPS-доступ к Docker repository, container registries и ACME.

1 vCPU/1 GiB подходит только для теста. Для рабочего использования рекомендуется минимум 2 vCPU, 2 GiB RAM и 20 GiB свободного места.

## Основной запуск

Для VPS у любого провайдера, кроме Timeweb:

```bash
curl -fsSL "https://github.com/marcusaure1ius/n8n-entrepreneur-starter-kit/releases/latest/download/install.sh" | sh
```

Для Timeweb VPS используйте их официальный Docker Hub proxy в той же
one-command форме:

```bash
curl -fsSL "https://github.com/marcusaure1ius/n8n-entrepreneur-starter-kit/releases/latest/download/install.sh" | N8N_IMAGE_SOURCE=timeweb sh
```

Stable URL перенаправляет на asset последнего GitHub Release. Каждый release сохраняет immutable versioned URL, checksum самого `install.sh` и exact Git commit; embedded archive дополнительно проверяется до любых системных изменений.

Автономный installer проверяет checksum встроенного exact-commit archive и устанавливает его в `/opt/n8n-entrepreneur-starter-kit`. Внутренний installer автоматически выбирает IP-derived hostname, устанавливает Docker из официального apt repository, генерирует два независимых секрета, создаёт `.env` с правами `0600`, проверяет Compose и ждёт healthy services.

Для разработчика автономный файл собирается так:

```bash
./scripts/build-one-command-installer.sh --output dist/install.sh
N8N_BOOTSTRAP_VERIFY_ONLY=1 sh dist/install.sh
```

Первую команду выполняют только из exact committed ref. Вторая проверяет встроенный SHA-256 без изменения системы.

Сначала безопасно посмотреть план:

```bash
./scripts/install.sh --non-interactive --dry-run
```

`--dry-run` не записывает файлы, не запускает `sudo`, не устанавливает packages и не меняет Docker runtime. `--check-only` выполняет только preflight. Оба режима могут сделать read-only DNS/HTTPS-запросы.

Firewall по умолчанию не меняется. Для него есть отдельный opt-in флаг installer и самостоятельный preview:

```bash
./scripts/firewall.sh --preview
./scripts/install.sh --configure-firewall
```

Активная SSH-сессия должна определяться через `SSH_CONNECTION`; иначе явно передайте проверенный `--ssh-port`. Non-interactive применение дополнительно требует `--yes`. Полный контракт и безопасная последовательность описаны в [security baseline](security.md).

## Non-interactive mode

Передавайте несекретные значения через environment, а секреты — через локальный файл mode `0600`:

```bash
install -m 0600 .env.example /root/n8n-install.env
sudo editor /root/n8n-install.env
./scripts/install.sh --non-interactive --config /root/n8n-install.env
```

Installer разбирает только разрешённые строки `KEY=VALUE` и не выполняет config как shell-код. Значения process environment имеют приоритет над `--config`, а `--config` — над существующим `.env`.

| Переменная | Обязательность | Назначение |
|---|---:|---|
| `N8N_HOST` | нет | custom FQDN; пусто — `n8n-<public-ip>.sslip.io` |
| `ACME_EMAIL` | нет | legacy contact override; default Caddy path его не требует |
| `TIMEZONE` | нет | IANA timezone, default `Etc/UTC` |
| `POSTGRES_DB` | нет | database, default `n8n` |
| `POSTGRES_USER` | нет | database user, default `n8n` |
| `POSTGRES_PASSWORD` | нет | генерируется, если данных ещё нет; custom value — минимум 24 безопасных dotenv-символа |
| `N8N_ENCRYPTION_KEY` | нет | генерируется один раз и должен сохраняться всегда; custom value — минимум 24 безопасных dotenv-символа |
| `EXECUTIONS_DATA_MAX_AGE` | нет | retention в часах, default `168` |
| `EXECUTIONS_DATA_PRUNE_MAX_COUNT` | нет | верхняя граница executions, default `10000` |
| `N8N_IMAGE_SOURCE` | нет | `official` по умолчанию; `timeweb` явно выбирает allowlisted Timeweb proxy с теми же exact tags |

`POSTGRES_IMAGE`, `N8N_IMAGE_REPOSITORY` и `CADDY_IMAGE` записываются installer в `.env`
из выбранного allowlisted source. Произвольные image references в beginner
path отклоняются.

Секреты не печатаются. Не передавайте их в shared shell history и CI logs.

## Повторный запуск и данные

- Существующий `.env` читается первым; его database password и `N8N_ENCRYPTION_KEY` сохраняются, если вы явно не передали другие значения.
- Если итоговая конфигурация меняется, interactive mode требует подтверждение. Non-interactive mode останавливается; после ручной проверки нужен `--yes`.
- `--yes` разрешает замену env-файла и, только вместе с явным `--configure-firewall`, подтверждает уже показанный UFW plan. SSH guard при этом не отключается. Installer никогда не выполняет `down --volumes`, не удаляет named volumes и не перезаписывает PostgreSQL data.
- Если volumes `n8n_data` или `n8n_postgres_data` существуют, а `.env` потерян, installer завершится с кодом `30`. Восстановите исходный `.env` из защищённой копии. Генерация нового encryption key поверх существующих данных небезопасна.
- Существующая рабочая установка Docker не заменяется автоматически. Отличие от проверенного baseline показывается как `WARN`.

## Preflight: PASS, WARN и FAIL

| Проверка | PASS | WARN | FAIL |
|---|---|---|---|
| ОС/architecture | Ubuntu 24.04 x86_64 | — | другая платформа |
| Ресурсы | минимум 1 CPU/1 GiB/10 GiB | меньше recommended 2 CPU/2 GiB/20 GiB | ниже minimum |
| Privileges | root или подтверждённый sudo | — | sudo недоступен |
| Порты | 80/443 свободны | заняты Caddy этого проекта при rerun | заняты другим процессом |
| Public hostname | auto sslip.io разрешается точно в public IPv4 | custom FQDN отличается при возможном NAT/proxy | auto hostname отсутствует/не совпадает или неверный формат |
| Network | Docker repository и n8n registry доступны | проверка отложена, если в read-only режиме нет curl | endpoint недоступен при установке |
| Docker | daemon и Compose доступны | existing versions отличаются от baseline | daemon/Compose недоступны или pinned packages отсутствуют |
| Image pull | exact images скачаны не более чем за три попытки | transient failure вызвал bounded backoff | попытки исчерпаны; для Timeweb выбрать `N8N_IMAGE_SOURCE=timeweb` |

DNS mismatch — предупреждение из-за возможного NAT, reverse proxy или propagation. Public HTTPS и certificate проверит `doctor.sh`; container health сам по себе их не доказывает.

## Exit codes

| Код | Значение |
|---:|---|
| `0` | success, check-only или dry-run завершены |
| `2` | ошибка аргументов или конфигурации |
| `10` | неподдерживаемая ОС |
| `11` | неподдерживаемая architecture |
| `12` | недостаточно ресурсов |
| `13` | нет root/sudo |
| `14` | конфликт ports |
| `16` | нет обязательной исходящей сети |
| `20` | Docker install/daemon failure |
| `21` | Docker Compose отсутствует или config невалиден |
| `22` | secret generation или безопасная запись env не удались |
| `23` | image pull/start failure |
| `24` | сервисы не достигли healthy |
| `30` | защита существующей конфигурации/data остановила запуск |

## После установки

```bash
docker compose ps
docker compose logs --tail=100 caddy n8n postgres
./scripts/firewall.sh --check
```

Откройте URL, напечатанный installer. Не публикуйте `.env`, не меняйте `N8N_ENCRYPTION_KEY` и не используйте `docker compose down --volumes`. Реальные DNS, certificate, webhook и reboot проверки требуют VPS evidence и не считаются пройденными локальным dry-run.
