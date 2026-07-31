# Quick Start: от чистого VPS до n8n

Первичная техническая проверка: 2026-07-14. Инструкция переработана по
результатам novice trial 2026-07-31. Собственный домен, Git и передача файлов
на VPS для базового пути не нужны.

## Результат

Вы создадите SSH-доступ, войдёте на Ubuntu VPS, запустите одну install-команду
и откроете n8n по обычному HTTPS-адресу.

## Перед началом

Подготовьте:

1. компьютер с **macOS/Linux Terminal** или **Windows 10/11 PowerShell**;
2. чистый VPS с **Ubuntu 24.04 LTS x86_64**;
3. публичный IPv4 VPS и доступ к панели провайдера;
4. открытые входящие TCP-порты `22`, `80` и `443`.

Рабочая конфигурация VPS: `2 vCPU`, `2 GiB RAM`, от `20 GiB` свободного
диска. `1 vCPU`, `1 GiB` и `10 GiB` — только нижняя граница короткого теста,
не рекомендация для постоянной работы.

Если VPS ещё нет, используйте [пошаговую инструкцию Timeweb](timeweb-clean-install.md),
[краткий Timeweb guide](timeweb-cloud.md) или [Yandex Cloud](yandex-cloud.md).

## Шаг 1. Создайте SSH-ключ на своём компьютере

Выберите только блок для своей локальной ОС. Во время `ssh-keygen` терминал
предложит passphrase. Придумайте её самостоятельно и сохраните в менеджере
паролей.

### macOS или Linux — Terminal

Скопируйте весь блок, вставьте в Terminal и нажмите Enter:

```bash
export VPS_KEY="$HOME/.ssh/id_ed25519_n8n"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
test -f "$VPS_KEY" || ssh-keygen -t ed25519 -a 64 -f "$VPS_KEY"
cat "$VPS_KEY.pub"
```

### Windows 10/11 — PowerShell

Скопируйте весь блок, вставьте в PowerShell и нажмите Enter:

```powershell
Get-Command ssh, ssh-keygen -ErrorAction Stop | Out-Null
$VpsKey = Join-Path $HOME ".ssh\id_ed25519_n8n"
New-Item -ItemType Directory -Force (Split-Path $VpsKey) | Out-Null
if (-not (Test-Path $VpsKey)) {
    ssh-keygen -t ed25519 -a 64 -f $VpsKey
}
Get-Content "$VpsKey.pub"
```

Если первая команда сообщает, что `ssh` или `ssh-keygen` не найдены,
установите только **OpenSSH Client** через Windows «Дополнительные
компоненты» по [инструкции Microsoft](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse).
OpenSSH Server на вашем компьютере не нужен.

**Ожидаемый результат:** последняя строка начинается с `ssh-ed25519`. Это
публичный ключ. Файл без окончания `.pub` — приватный; не загружайте и не
отправляйте его никому.

## Шаг 2. Добавьте публичный ключ на VPS

1. Скопируйте целиком строку `ssh-ed25519 ...`, напечатанную на шаге 1.
2. При создании VPS вставьте её в **Authorization / SSH key**.
3. Если Timeweb VPS уже создан: откройте карточку сервера → **Доступ** →
   **SSH-ключи / Изменить** → **Загрузить новый ключ**.
4. Вставьте публичный ключ, сохраните изменение и подождите пару минут.

**Ожидаемый результат:** новый ключ отображается в панели и выбран для этого
VPS. На Timeweb перезагрузка сервера не требуется.

## Шаг 3. Войдите на VPS

Скопируйте IPv4 из карточки сервера. Не вставляйте адрес внутрь блока кода:
сначала выполните блок, а затем дождитесь приглашения `IPv4 вашего VPS:`.

### macOS или Linux — Terminal

```bash
printf 'IPv4 вашего VPS: '
read -r VPS_IP
ssh -i "$VPS_KEY" "root@$VPS_IP"
```

Когда появится `IPv4 вашего VPS:`, вставьте только адрес из панели, например
четыре группы цифр через точки, и нажмите Enter.

### Windows — PowerShell

```powershell
$VpsIp = Read-Host "IPv4 вашего VPS"
ssh -i $VpsKey "root@$VpsIp"
```

Когда PowerShell попросит IPv4, вставьте только адрес из панели и нажмите
Enter.

При первом подключении SSH покажет fingerprint. Сравните его с данными панели,
если провайдер их показывает, затем напишите `yes`.

**Ожидаемый результат:** строка терминала начинается с `root@...`. Все
следующие команды выполняются уже на Ubuntu VPS и одинаковы для Windows,
macOS и Linux.

Если появилось `Permission denied (publickey)`, public key ещё не добавлен на
этот VPS либо выбран другой private key. Вернитесь к шагу 2 и не переходите к
установке.

## Шаг 4. Установите n8n

Выберите одну команду по провайдеру VPS.

### VPS в Timeweb Cloud

Команда использует [официальный proxy Timeweb](https://dockerhub.timeweb.cloud/),
чтобы не зависеть от общего лимита Docker Hub, и сохраняет exact версии
образов:

```bash
curl -fsSL "https://github.com/marcusaure1ius/n8n-entrepreneur-starter-kit/releases/latest/download/install.sh" | N8N_IMAGE_SOURCE=timeweb sh
```

### Другой провайдер

```bash
curl -fsSL "https://github.com/marcusaure1ius/n8n-entrepreneur-starter-kit/releases/latest/download/install.sh" | sh
```

Скопируйте выбранную строку целиком, вставьте в SSH-сессию и нажмите Enter.
Не закрывайте терминал. Скачивание и первый запуск контейнеров могут занять
несколько минут.

**Ожидаемый результат:** installer показывает последовательность `[PASS]`, а
в конце печатает:

```text
Установка завершена.
  URL: https://n8n-<ваш-IP-с-дефисами>.sslip.io/
```

Если предыдущая попытка на Timeweb закончилась `429 Too Many Requests`,
повторите именно Timeweb-команду выше. Существующий `.env`, encryption key,
пароль PostgreSQL и Docker volumes сохраняются.

## Шаг 5. Откройте n8n

1. Скопируйте URL из строки `Установка завершена`.
2. Откройте его в браузере.
3. Создайте первого owner.
4. Сохраните уникальный пароль в менеджере паролей. Не отправляйте пароль
   преподавателю, агенту или в чат.

**Готово, когда:** браузер показывает редактор n8n по HTTPS, без предупреждения
о сертификате.

## Шаг 6. Проверьте состояние

В SSH-сессии выполните:

```bash
cd /opt/n8n-entrepreneur-starter-kit
sudo ./scripts/doctor.sh
sudo docker compose ps
```

Ожидается `FAIL=0`; `postgres`, `n8n` и `caddy` имеют состояние
`running/healthy`.

## Если что-то пошло не так

| Сообщение | Действие |
|---|---|
| `Permission denied (publickey)` | вернитесь к шагу 2 и проверьте, что на VPS добавлен `.pub` именно созданного ключа |
| `429 Too Many Requests` на Timeweb | повторите Timeweb-команду из шага 4; exact tags сохраняются |
| checksum release не совпал | остановитесь: не обходите проверку |
| ОС не Ubuntu 24.04 или architecture не x86_64 | пересоздайте VPS с поддерживаемым образом |
| hostname не разрешается в IP VPS | остановитесь и используйте [диагностику](troubleshooting.md) |
| порты 80/443 заняты | не завершайте процессы вслепую; используйте [диагностику](troubleshooting.md) |
| installer или doctor показывает `[FAIL]` | остановитесь на первой ошибке и откройте [troubleshooting](troubleshooting.md) |

Не публикуйте `.env`, не меняйте `N8N_ENCRYPTION_KEY` и не запускайте
`docker compose down --volumes`.

## Что делает installer

Installer проверяет SHA-256 exact release, Ubuntu и architecture; определяет
публичный IPv4; создаёт бесплатный hostname через sslip.io; устанавливает
pinned Docker, PostgreSQL, n8n и Caddy; создаёт постоянные secrets в `.env`
mode `0600`; выполняет не более трёх попыток pull и ждёт healthy services.

[sslip.io](https://sslip.io/) возвращает IP, записанный в hostname, поэтому
собственный домен для первого запуска не нужен. Если эта внешняя зависимость
недоступна, installer останавливается и не включает небезопасный HTTP. Позже
можно перейти на [собственный домен](domain-and-dns.md).
