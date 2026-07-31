# ADR-0012: Явный Timeweb proxy для Docker Hub rate limits

- Статус: Accepted
- Дата: 2026-07-31
- Дополняет: ADR-0003 и ADR-0004

## Context

Реальный novice trial `T-0032` дважды дошёл до установки Docker, но первый
Compose pull завершился `429 Too Many Requests` на Docker Hub. Документация
ссылалась на recovery, которого в troubleshooting фактически не было. Blind
retry не устраняет длительный rate limit общего provider IP, а замена exact
tags на `latest` запрещена ADR-0003.

Timeweb публикует официальный Docker Hub proxy
`dockerhub.timeweb.cloud` и документирует как daemon mirror, так и явные image
references. Installer не может надёжно определять cloud provider по public IP,
поэтому автоматическое переключение registry без выбора пользователя
небезопасно.

## Decision

- Default `N8N_IMAGE_SOURCE=official` сохраняет исходные registry и exact tags.
- Для VPS Timeweb Quick Start использует ту же one-command форму с явным
  `N8N_IMAGE_SOURCE=timeweb` перед `sh`.
- Timeweb source меняет только registry host/path. Версии PostgreSQL
  `17.10-bookworm`, n8n `2.29.10` и Caddy `2.11.4-alpine` не меняются.
- Выбранные exact image references сохраняются в `.env` mode `0600`, поэтому
  обычные Compose и doctor используют тот же source после установки.
- Pull выполняется не более трёх раз с ограниченным backoff. После исчерпания
  installer останавливается и не делает бесконечный retry или downgrade.
- Произвольный registry/image override не поддерживается в beginner path:
  parser принимает только согласованные наборы `official` и `timeweb`.

## Consequences

- Timeweb onboarding не зависит от anonymous Docker Hub rate limit общего IP.
- Пользователь явно видит provider-specific dependency; скрытой geo/ASN
  эвристики нет.
- Proxy становится внешней зависимостью только выбранного Timeweb path.
- Release evidence по-прежнему обязано фиксировать resolved digests после
  фактического pull.

## Evidence

- [Timeweb Docker Hub proxy](https://dockerhub.timeweb.cloud/)
- `T-0032` novice trial, 2026-07-31: Docker Hub вернул `429` на
  `caddy:2.11.4-alpine` через 4 минуты 54 секунды повторного прохода.
