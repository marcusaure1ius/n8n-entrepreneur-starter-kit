# Подготовка VM в Yandex Cloud

Проверено по официальной документации: 2026-07-14. UI меняется; используйте текущую [инструкцию создания Linux VM](https://yandex.cloud/ru/docs/compute/operations/vm-create/create-linux-vm) и проверяйте результат командами, а не по screenshots.

## Итог этого guide

VM Compute Cloud с Ubuntu 24.04 LTS x86_64, статическим публичным IPv4, SSH key и security group для SSH/HTTP/HTTPS. Затем сразу выполните [Quick Start одной командой](quick-start.md); [собственный домен](domain-and-dns.md) необязателен.

## 1. Создайте SSH key

Для macOS или Linux откройте Terminal:

```bash
test -f "$HOME/.ssh/id_ed25519_n8n" || \
  ssh-keygen -t ed25519 -a 64 -f "$HOME/.ssh/id_ed25519_n8n"
```

Для Windows 10/11 откройте PowerShell:

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

Приватный key не загружается в cloud и не отправляется другим людям. Официальная последовательность key → VM → connection описана в [Yandex Cloud SSH guide](https://yandex.cloud/en/docs/compute/operations/vm-connect/ssh).

## 2. Создайте VM

В каталоге откройте Compute Cloud → «Виртуальные машины» → «Создать виртуальную машину». Для публичного IPv4 вашей учётной записи могут потребоваться роли `compute.editor` и `vpc.publicAdmin`, как указано в официальном guide.

| Настройка | Выбор |
|---|---|
| Boot image | публичный Ubuntu 24.04 LTS, без preinstalled application |
| Architecture | x86_64/amd64 |
| Рабочий размер | 2 vCPU, 2 GiB RAM, boot disk от 20 GiB |
| Только минимальный тест | 1 vCPU, 1 GiB RAM, disk от 10 GiB |
| Public IP | зарезервированный статический IPv4 в той же зоне |
| Access | отдельный username и содержимое public SSH key |
| OS Login | не включайте, если не понимаете его IAM lifecycle; обычный SSH key path поддерживается |

1 GiB/10 GiB — только нижняя тестовая граница. Не выбирайте прерываемую VM для постоянного n8n.

Для DNS нужен стабильный адрес. Зарезервируйте его в Virtual Private Cloud → «Публичные IP-адреса» по официальной [инструкции static IP](https://yandex.cloud/en/docs/vpc/operations/get-static-ip), затем выберите этот адрес при создании VM. Динамический IP может измениться после остановки VM.

## 3. Настройте security group

Правила применяются к VM сразу, без reboot; порядок UI описан в [официальном guide](https://yandex.cloud/ru/docs/vpc/operations/security-group-add-rule).

Входящие правила:

| Protocol/port | Source | Назначение |
|---|---|---|
| TCP 22 или ваш SSH port | ваш стабильный public IP `/32`, если возможно | SSH |
| TCP 80 | `0.0.0.0/0` | ACME HTTP challenge/redirect |
| TCP 443 | `0.0.0.0/0` | n8n HTTPS |
| UDP 443 | `0.0.0.0/0` | HTTP/3, необязательно |

Оставьте исходящий DNS/HTTPS доступ. Не создавайте правило для PostgreSQL `5432` или n8n `5678`: они приватны внутри Compose. Если временно разрешили SSH из `0.0.0.0/0`, сузьте source после успешного входа, не удаляя рабочее правило до проверки новой SSH-сессии.

## 4. Проверьте VM по IP

Для macOS или Linux:

```bash
export VPS_USER="yc-user"
printf 'Пользователь VPS [yc-user]: '
read -r VPS_USER_INPUT
test -z "$VPS_USER_INPUT" || VPS_USER="$VPS_USER_INPUT"
printf 'IPv4 вашего VPS: '
read -r VPS_IP
ssh -i "$HOME/.ssh/id_ed25519_n8n" "$VPS_USER@$VPS_IP"
```

Для Windows PowerShell:

```powershell
$VpsUser = Read-Host "Пользователь VPS [yc-user]"
if ([string]::IsNullOrWhiteSpace($VpsUser)) {
    $VpsUser = "yc-user"
}
$VpsIp = Read-Host "IPv4 вашего VPS"
ssh -i $VpsKey "$VpsUser@$VpsIp"
```

`VPS_USER` должен совпадать с username, заданным при создании VM; `yc-user` — только типичный default для CLI path, а не универсальное предположение.

На VM:

```bash
. /etc/os-release
printf 'OS=%s VERSION=%s ARCH=%s\n' "$ID" "$VERSION_ID" "$(uname -m)"
test "$ID" = ubuntu
test "$VERSION_ID" = 24.04
test "$(uname -m)" = x86_64
sudo -v
```

Ожидается `OS=ubuntu VERSION=24.04 ARCH=x86_64`. Если VM не `RUNNING`, public IP отсутствует или security group не разрешает SSH, исправьте cloud configuration до установки.

## Безопасная диагностика

| Симптом | Проверка без изменения данных |
|---|---|
| SSH timeout | VM `RUNNING`, Public IPv4 заполнен, TCP 22 разрешён security group |
| `Permission denied` | username совпадает с metadata, используется соответствующий private key |
| IP изменился | зарезервировать static IP и обновить A-record; не обходить проблему hosts-файлом |
| Нет внешнего HTTPS | проверить TCP 80/443 в security group, DNS и Caddy logs |
| Потерян SSH key | использовать официальный recovery/serial-console path; не удалять disk/VM без backup |

Реальная VM, billing, SSH и security group этой документационной задачей не создавались. Их успех подтверждается только командами на вашем ресурсе.
