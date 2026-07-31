# Подготовка VPS в Timeweb Cloud

Проверено по официальной документации: 2026-07-14. Названия кнопок в панели могут измениться; опирайтесь на обязательные параметры ниже и актуальную [инструкцию создания сервера](https://timeweb.cloud/docs/cloud-servers/manage-servers/create-server), а не только на screenshots. Реальный проход от заказа до публичного HTTPS с безопасными скриншотами находится в [пошаговой инструкции Timeweb](timeweb-clean-install.md).

## Итог этого guide

Чистый сервер с Ubuntu 24.04 LTS x86_64, закреплённым за аккаунтом публичным IPv4, рабочим SSH и открытыми TCP 22/80/443. После проверки сразу переходите к [Quick Start одной командой](quick-start.md). [Собственный домен](domain-and-dns.md) необязателен.

## 1. Подготовьте SSH key

На macOS или Linux создайте отдельную пару в Terminal, если её ещё нет:

```bash
test -f "$HOME/.ssh/id_ed25519_n8n" || \
  ssh-keygen -t ed25519 -a 64 -f "$HOME/.ssh/id_ed25519_n8n"
```

На Windows 10/11 откройте PowerShell:

```powershell
Get-Command ssh, ssh-keygen -ErrorAction Stop | Out-Null
$VpsKey = Join-Path $HOME ".ssh\id_ed25519_n8n"
New-Item -ItemType Directory -Force (Split-Path $VpsKey) | Out-Null
if (-not (Test-Path $VpsKey)) {
    ssh-keygen -t ed25519 -a 64 -f $VpsKey
}
Get-Content "$VpsKey.pub"
```

Если OpenSSH Client не найден, установите его через Windows «Дополнительные
компоненты» по [инструкции Microsoft](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse).

Приватный файл остаётся только у вас. В панель загружается содержимое `.pub`. Timeweb описывает добавление key при создании сервера в официальном [руководстве по SSH-ключам](https://timeweb.cloud/docs/cloud-servers/manage-servers/ssh-keys).

## 2. Создайте сервер

В «Облачные серверы» нажмите «Создать/Добавить» и задайте инварианты:

| Настройка | Выбор |
|---|---|
| Software | чистая ОС, не Marketplace application image |
| ОС | Ubuntu 24.04 LTS |
| Architecture | x86_64/amd64 |
| Рабочий размер | 2 vCPU, 2 GiB RAM, диск от 20 GiB |
| Только минимальный тест | 1 vCPU, 1 GiB RAM, диск от 10 GiB |
| Network | новый или существующий публичный IPv4 |
| Authorization | созданный SSH public key |
| cloud-init | пусто; installer выполнит настройку сам |

1 GiB/10 GiB не называйте production sizing. GPU, preinstalled n8n, WordPress и панели управления не входят в поддерживаемый путь.

Публичные IPv4 Timeweb являются отдельным ресурсом аккаунта и могут переноситься между сервисами; это описано в [обзоре публичных IP](https://timeweb.cloud/docs/public-ip). Не отвязывайте адрес после настройки DNS.

## 3. Проверьте SSH до firewall

Скопируйте IPv4 из dashboard. Команда сама попросит адрес и не содержит
чужого примера. Для macOS или Linux:

```bash
export VPS_KEY="$HOME/.ssh/id_ed25519_n8n"
printf 'IPv4 вашего VPS: '
read -r VPS_IP
ssh -i "$HOME/.ssh/id_ed25519_n8n" "root@$VPS_IP"
```

Для Windows PowerShell:

```powershell
$VpsIp = Read-Host "IPv4 вашего VPS"
ssh -i $VpsKey "root@$VpsIp"
```

При первом соединении не подтверждайте fingerprint вслепую: сравните его с console/provider data, если они доступны. Официальный формат подключения приведён в [Timeweb SSH guide](https://timeweb.cloud/docs/unix-guides/ssh).

На сервере:

```bash
. /etc/os-release
printf 'OS=%s VERSION=%s ARCH=%s\n' "$ID" "$VERSION_ID" "$(uname -m)"
test "$ID" = ubuntu
test "$VERSION_ID" = 24.04
test "$(uname -m)" = x86_64
sudo -v
```

Ожидается `OS=ubuntu VERSION=24.04 ARCH=x86_64`. Если образ не совпал, пересоздайте сервер до появления данных.

## 4. Cloud firewall

Timeweb Firewall управляется отдельно от host UFW; официальный обзор — [Firewall as a Service](https://timeweb.cloud/docs/firewall). Не подключайте deny-only policy, пока новая SSH-сессия не проверена.

Минимальные входящие правила для этого проекта:

| Protocol/port | Source | Назначение |
|---|---|---|
| TCP 22 или ваш SSH port | ваш стабильный public IP `/32`, если возможно | SSH |
| TCP 80 | `0.0.0.0/0` | ACME HTTP challenge/redirect |
| TCP 443 | `0.0.0.0/0` | n8n HTTPS |
| UDP 443 | `0.0.0.0/0` | HTTP/3, необязательно |

Исходящий HTTPS/DNS должен оставаться доступным для Docker registries, ACME и provider APIs. После применения cloud rules откройте вторую SSH-сессию и только затем рассматривайте host UFW из [security guide](security.md).

## Безопасная диагностика

| Симптом | Проверка без разрушения данных |
|---|---|
| `Connection timed out` | сервер running, IPv4 привязан, cloud firewall разрешает SSH |
| `Permission denied (publickey)` | выбран правильный user/key; public key добавлен в «Авторизация» |
| Ubuntu/version не совпадает | пересоздать с clean Ubuntu 24.04, не менять distribution in-place |
| После firewall пропал SSH | использовать provider console, вернуть SSH allow-rule; не переустанавливать VPS сразу |
| 80/443 недоступны | проверить cloud rules, затем `sudo ss -ltnp`; PostgreSQL наружу не открывать |

Стоимость, доступные регионы и UI являются внешними изменчивыми фактами: перед покупкой перепроверьте их в панели. Этот guide не подтверждает фактическое создание или оплату ресурса.
