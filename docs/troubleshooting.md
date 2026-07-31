# Troubleshooting

Проверено: 2026-07-14; recovery Docker Hub `429` обновлён по novice trial 2026-07-31. Руководство соответствует текущим scripts и pinned Compose baseline. Начинайте с read-only диагностики и останавливайтесь при первом `FAIL`; не удаляйте volumes, не меняйте `N8N_ENCRYPTION_KEY` и не делайте image-only downgrade ради «быстрого исправления».

```bash
./scripts/doctor.sh --local-only
./scripts/doctor.sh
```

Doctor возвращает `0` при одних `OK`, `1` при `WARN`, `2` при `FAIL`. Перед передачей ручных logs удалите PII, tokens, webhook URLs и query parameters.

## Docker Hub вернул `429 Too Many Requests`

**Симптом:** installer завершился на `docker compose pull`, а output содержит
`429 Too Many Requests` и `[FAIL] Не удалось скачать pinned images`.

**Проверка:** убедитесь, что VPS действительно находится в Timeweb. Не меняйте
image tags и не удаляйте созданный `.env` или volumes.

**Решение:** на Timeweb повторите опубликованную команду с явным source:

```bash
curl -fsSL "https://github.com/marcusaure1ius/n8n-entrepreneur-starter-kit/releases/latest/download/install.sh" | N8N_IMAGE_SOURCE=timeweb sh
```

Installer использует [официальный proxy Timeweb](https://dockerhub.timeweb.cloud/),
но сохраняет exact версии PostgreSQL, n8n и Caddy. Выбор записывается в `.env`;
secrets и данные повторно не создаются. Pull имеет максимум три попытки. Если
они исчерпаны, остановитесь: не включайте `latest`, произвольный mirror или
бесконечный retry.

Для другого cloud provider используйте его официальный registry recovery или
дождитесь снятия лимита Docker Hub; Timeweb proxy не включается автоматически
по IP и не является общим default.

## n8n не открывается

**Симптом:** browser показывает timeout/502, а editor недоступен.

**Проверка:** выполните `./scripts/doctor.sh --local-only`, затем `docker compose ps`. Если `runtime.n8n` или `service.n8n` имеет `FAIL`, посмотрите только последние строки: `docker compose logs --tail 100 n8n`.

**Решение:** дождитесь healthy state после запуска. При database error сначала исправьте PostgreSQL-сценарий ниже; при неверном public URL исправьте `.env` штатным installer/config flow и пересоздайте n8n. Не публикуйте полный log: он может содержать PII.

## PostgreSQL unhealthy

**Симптом:** doctor сообщает `runtime.postgres` или `service.postgres` как `FAIL`, n8n перезапускается.

**Проверка:** выполните `docker compose ps` и `docker compose logs --tail 100 postgres`; проверьте свободное место через `df -h`. Не печатайте `.env`.

**Решение:** освободите место вне persistent volumes и повторите doctor. Если `.env` потерян при существующих volumes, восстановите исходный env из согласованного backup — не генерируйте новый database password или encryption key поверх данных. Повреждение database восстанавливайте только по [backup/restore guide](backup-and-restore.md).

## DNS работает, HTTPS нет

**Симптом:** A-record уже указывает на VPS, но certificate не выпускается или browser показывает TLS error.

**Проверка:** выполните полный `./scripts/doctor.sh`; отдельно сравните `external.dns`, `external.https` и `external.certificate`. Проверьте `docker compose logs --tail 100 caddy`, TCP `80/443` в cloud firewall и UFW.

**Решение:** исправьте A-record и доступность TCP `80/443`, затем дождитесь повторной попытки Caddy. Не используйте TLS bypass как доказательство исправления и не отключайте certificate verification. UDP `443` нужен только для HTTP/3 и не заменяет TCP.

## `.env` отсутствует или имеет неверные права

**Симптом:** script пишет `Env-файл отсутствует` или `Env-файл должен иметь mode 0600`.

**Проверка:** из корня проекта выполните `stat -c '%a %n' .env` на Ubuntu. Не используйте `cat .env` и не прикладывайте файл к тикету.

**Решение:** если это новая установка, снова запустите installer. Если volumes уже содержат данные, восстановите исходный `.env` из recovery archive. Для существующего корректного файла исправьте только mode: `chmod 600 .env`.

## Backup не создаётся

**Симптом:** `backup.sh` завершается `[FAIL]`, нет строки `BACKUP_ARCHIVE=` или нет sidecar `.sha256`.

**Проверка:** выполните `./scripts/doctor.sh --local-only`, проверьте running PostgreSQL, четыре named volumes, свободное место и отсутствие другого backup lock. Посмотрите точное redacted сообщение script.

**Решение:** устраните конкретный preflight failure и повторите `./scripts/backup.sh`. Не переименовывайте partial file в готовый archive и не считайте backup успешным без sidecar checksum. Не удаляйте старые archives вручную, пока новый не проверен.

## Restore отклоняет archive

**Симптом:** `restore.sh` сообщает `Outer archive checksum mismatch`, `Payload checksum mismatch`, несовместимый schema/image или небезопасный path.

**Проверка:** убедитесь, что archive и одноимённый `.sha256` получены одной парой и не изменялись. Не распаковывайте и не «чините» archive вручную.

**Решение:** используйте другую проверенную копию. Checksum failure обязан остановить restore до mutation. Для существующего runtime не обходите safety backup и cross-identity guard; если mutation уже началась и automatic rollback не удался, используйте напечатанный `SAFETY_ARCHIVE` по процедуре восстановления.

## Update остановился или оставил `update_pending`

**Симптом:** update вернул non-zero, doctor имеет `FAIL`, metadata показывает `update_pending`.

**Проверка:** сохраните напечатанные `BACKUP_ARCHIVE` и `STATE_FILE`, выполните `./scripts/doctor.sh --local-only` и проверьте текущий `N8N_VERSION` без вывода остальных env values.

**Решение:** выполните точную recovery-команду `rollback.sh`, которую напечатал `update.sh`. Не меняйте tag вручную и не удаляйте lifecycle metadata. Если old image или pre-update archive отсутствует, остановитесь: unsafe downgrade запрещён.

## Credentials перестали расшифровываться

**Симптом:** после переноса/restore nodes сообщают credential/decryption errors.

**Проверка:** выясните, восстановлены ли database, `n8n_data` и исходный `.env` из одного backup. Не выводите `N8N_ENCRYPTION_KEY` для сравнения.

**Решение:** восстановите согласованный archive целиком. Не заменяйте master `N8N_ENCRYPTION_KEY` новым значением. Если потерян единственный экземпляр исходного ключа и нет recovery archive, starter kit не заявляет безопасного способа расшифровать старые credentials: создайте credentials заново и отзовите скомпрометированные provider secrets.

## После firewall пропал доступ

**Симптом:** новая SSH-сессия или HTTPS не устанавливается после изменения rules.

**Проверка:** не закрывайте текущую SSH-сессию. В ней выполните `./scripts/firewall.sh --check`; сверяйте server port с `SSH_CONNECTION` и отдельно проверьте cloud security group.

**Решение:** из текущей сессии или provider console восстановите allow-rule для фактического SSH port, затем TCP `80/443`. Перед следующим apply всегда используйте `--preview`. Script не удаляет сторонние rules и не может автоматически исправить provider firewall.

## Удаление данных не запускается

**Симптом:** uninstall отказывается удалить volumes или сообщает другой Compose working directory.

**Проверка:** выполните `./scripts/uninstall.sh --help` и проверьте, что containers принадлежат текущему project root. Обычный `./scripts/uninstall.sh` сохраняет данные.

**Решение:** не удаляйте containers/volumes вручную при ownership mismatch. Для намеренного необратимого удаления сначала создайте backup, затем используйте одновременно `--delete-data` и точную фразу `--confirm-delete DELETE-N8N-DATA`. Команда без обоих предохранителей должна отказать.

## Потерян доступ к 2FA

**Симптом:** authenticator недоступен и вход требует одноразовый код.

**Проверка:** найдите сохранённый recovery code в защищённом хранилище. Переменная `N8N_MFA_ENABLED=false` не отключает 2FA у уже настроенного пользователя.

**Решение:** используйте один recovery code. Если recovery codes тоже потеряны, остановитесь и сверяйте recovery procedure с [актуальной официальной документацией 2FA](https://docs.n8n.io/user-management/two-factor-auth/) для установленной версии; не редактируйте user tables вручную.

## Что подтверждено, а что нет

Локальный disposable rehearsal с реальными pinned containers подтвердил backup/delete/restore, update/rollback и data-preserving uninstall/restart; exact среда и hashes находятся в [dated report](reports/2026-07-14-destructive-lifecycle.md). Static/integration quality gates запускаются командой `make quality`.

Реальный Ubuntu VPS, DNS/ACME/public HTTPS, reboot persistence, cloud firewall и provider credentials этим rehearsal не проверены. Для них нужен отдельный evidence run; отсутствие локальной ошибки не означает production success.
