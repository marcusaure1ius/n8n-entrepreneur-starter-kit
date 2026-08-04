# n8n Entrepreneur Starter Kit

> **Репозиторий переехал.** Разработка продолжается в
> <https://github.com/marcusaure1ius/alfa-ai-course>, где starter kit и Course
> Control Plane живут вместе. Этот репозиторий переведён в архив и доступен
> только для чтения.
>
> Актуальная установка одной командой:
>
> ```bash
> curl -fsSL "https://github.com/marcusaure1ius/alfa-ai-course/releases/latest/download/install.sh" | sh
> ```
>
> Релизы `v0.1.0`–`v0.1.3` здесь остаются доступными: по ним можно откатиться и
> проверить ранее опубликованные checksum. Новые релизы выходят только в новом
> репозитории.

Production-minded starter kit для самостоятельного развёртывания официального self-hosted n8n Community Edition предпринимателем без опыта DevOps.

## Статус проекта

Foundation/onboarding, official research и architecture gate завершены. Pinned Compose runtime, installer, diagnostics и security baseline подготовлены; владелец одобрил MVP backlog 2026-07-13, а актуальный lifecycle/status задач остаётся в Projects Control.

## Установка одной командой

На чистой Ubuntu 24.04 LTS x86_64 выполните от `root` или пользователя с `sudo`:

```bash
curl -fsSL "https://github.com/marcusaure1ius/n8n-entrepreneur-starter-kit/releases/latest/download/install.sh" | sh
```

Собственный домен, ручная DNS-запись, `git clone` и передача archive не нужны. Installer опубликован в GitHub Releases; immutable checksum и exact commit доступны в конкретном release.

## Цель MVP

Пользователь с чистым VPS на Ubuntu 24.04 LTS, публичным IPv4 и sudo-доступом должен одной командой развернуть собственный экземпляр n8n с PostgreSQL и HTTPS за 15–30 минут. Покупка домена и ручная настройка DNS для базового пути не нужны.

Starter kit не является SaaS, не перепродаёт доступ к n8n, не использует white label и не запускает LLM локально.

## Зафиксированные границы

- целевая ОС: Ubuntu 24.04 LTS x86_64;
- оркестрация: Docker Compose;
- обязательные сервисы: официальный образ n8n Community Edition, PostgreSQL и Caddy;
- постоянные данные: отдельные Docker volumes;
- внешний доступ: HTTPS, PostgreSQL наружу не публикуется;
- LLM: внешние API через заменяемый LLM Gateway;
- основной интерфейс установки после входа на VPS: один автономный HTTPS bootstrap вида `curl -fsSL <адрес>/install.sh | sh`;
- стартовый hostname автоматически строится из публичного IPv4 через `sslip.io`; собственный домен — необязательное улучшение;
- версии контейнеров явно закреплены в ADR-0003 по dated official-source research;
- Redis, queue workers, Kubernetes, Ollama, Qdrant и LiteLLM не входят в базовый профиль.

## Канонические документы

- [Product brief](docs/product-brief.md) — пользователи, проблема, цели и критерии MVP;
- [Архитектура](docs/architecture.md) — компоненты, потоки, trust boundaries и quality gates;
- [MVP backlog](docs/backlog.md) — эпики, задачи и зависимости;
- [AGENTS.md](AGENTS.md) — обязательный рабочий протокол для агентов;
- [ADR-0001](adr/0001-platform-and-scope.md) — платформа и границы базового профиля;
- [ADR-0002](adr/0002-llm-integration-strategy.md) — стратегия интеграции LLM;
- [ADR-0003](adr/0003-version-pinning-policy.md) — политика выбора и фиксации версий.
- [ADR-0004](adr/0004-domainless-one-command-onboarding.md) — установка одной командой без собственного домена;
- [Platform/version/license research](docs/research/2026-07-13-platform-versions-and-license.md) — dated official-source baseline;
- [Provider capability matrix](docs/research/provider-capabilities.md) — verified/unverified paths для n8n, Yandex, GigaChat и Bitrix24;
- [LLM Gateway contract](docs/contracts/llm-gateway.md) — normalized inputs, outputs, errors и secret rules;
- [Runtime configuration](docs/runtime-configuration.md) — Compose files, variables, topology and health semantics;
- [Quick Start](docs/quick-start.md) — путь от чистого VPS до HTTPS n8n одной командой;
- [Timeweb Cloud](docs/timeweb-cloud.md) — чистый Ubuntu VPS, public IPv4 и безопасный SSH;
- [Фактическая установка в Timeweb](docs/timeweb-clean-install.md) — пошаговый проход со стоимостью, безопасными скриншотами, HTTPS evidence и решением Docker Hub `429`;
- [Yandex Cloud](docs/yandex-cloud.md) — Compute Cloud VM, static IP и security group;
- [Домен и DNS](docs/domain-and-dns.md) — необязательный переход со стартового адреса на собственный домен;
- [Установка](docs/installation.md) — preflight, interactive/non-interactive modes, rerun safety и exit codes;
- [Публикация installer](docs/release-publication.md) — stable URL, immutable release, checksum и проверка артефакта;
- [Security baseline](docs/security.md) — least-privilege defaults, retention и SSH-safe opt-in UFW;
- [Диагностика](docs/diagnostics.md) — redacted OK/WARN/FAIL report и symptom mapping;
- [Troubleshooting](docs/troubleshooting.md) — безопасные сценарии симптом → проверка → решение;
- [Participant handoff](docs/participant-handoff.md) — проверяемая передача владения и операционной ответственности;
- [Instructor guide](docs/instructor-guide.md) — подготовка, проведение и безопасная поддержка курса;
- [Backup и restore](docs/backup-and-restore.md) — recovery archive, checksums, safety backup и rehearsal;
- [Update и rollback](docs/update-and-rollback.md) — approved version pair, backup gate и restore-based recovery;
- [Uninstall и перенос workflow](docs/uninstall-and-workflow-portability.md) — data-preserving uninstall, credential-free deterministic export и repeatable batch import;
- [Destructive lifecycle report](docs/reports/2026-07-14-destructive-lifecycle.md) — реальный disposable backup/delete/restore, update/rollback и uninstall/restart с exact data assertions;
- [Ubuntu 24.04 E2E report](docs/reports/2026-07-14-ubuntu-e2e.md) — clean install/rerun, reboot, ports, local TLS, workflow import и lifecycle verification на x86_64 guest с явной границей public VPS evidence;
- [Quality gates](tests/README.md) — единая команда, local/CI matrix, redacted artifacts и честные external skips;
- [Generic LLM provider](docs/generic-llm-provider.md) — gateway contract, Connection Test и credential-safe setup;
- [LLM providers](docs/llm-providers.md) — Yandex AI Studio adapter/model diagnostics и GigaChat OAuth lifecycle, scopes, rotation и troubleshooting;
- [Credentials и интеграции](docs/credentials.md) — единый безопасный порядок подключения, smoke, evidence, rotation и incident response;
- [Mail gateway contract](docs/contracts/mail.md) — IMAP normalization, safe drafts, approval-bound SMTP и loop protection;
- [Email integration](docs/email.md) — порядок IMAP → draft → approval-bound SMTP и ссылка на credential setup;
- [Telegram sender contract](docs/contracts/telegram.md) — allowlist, safe modes, idempotency и normalized errors;
- [Telegram integration](docs/telegram.md) — BotFather, token-safe credential, allowlist и controlled smoke;
- [CRM integration](docs/crm.md) — OAuth2 Bitrix24, least privilege, preview/rehearsal и rotation;
- [Telegram Assistant](docs/workflows/telegram-assistant.md) — draft-only demo, owner approval commands, dedupe и loop guards;
- [Email Assistant](docs/workflows/email-assistant.md) — IMAP setup, guarded LLM extraction, draft-only output и privacy notes;
- [Lead Handler](docs/workflows/lead-handler.md) — Header Auth webhook, нормализация контакта, approval-bound CRM mutation и recovery;
- [Daily Executive Digest](docs/workflows/daily-executive-digest.md) — окно 09:00 MSK, event-source coverage, privacy-minimized summary и честные `partial`/`н/д` метрики;
- [Каталог workflow и test report](docs/workflow-catalog-and-test-report.md) — 18 workflow, import order, fixture coverage, clean pinned import и границы mock/external evidence;
- [Apache License 2.0](LICENSE) — лицензия оригинальных файлов starter kit;
- [License notes](LICENSE-NOTES.md) — границы лицензии starter kit, n8n и сторонних компонентов.

## Лицензия

Оригинальные файлы этого starter kit распространяются по [Apache License 2.0](LICENSE). n8n, container images, зависимости и сторонние assets сохраняют собственные лицензии; подробная граница описана в [LICENSE-NOTES.md](LICENSE-NOTES.md).
