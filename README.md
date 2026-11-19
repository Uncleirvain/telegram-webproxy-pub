# Telegram WEB Proxy: HTTPS Lanes + Caddy + TrafficGuard

**Community installer for a NEW VPS.** Один общий WEB Proxy secret для нескольких клиентских устройств, один домен, статический HTTPS-сайт, автоматический Let's Encrypt через Caddy и опциональная IP-фильтрация TrafficGuard.

> **Внимание:** `telegramdesktop/tproxy-server` — proof-of-concept. Нужен Telegram-клиент с поддержкой типа `WEB`; стандартные клиенты не обязательно его поддерживают. Это не VPN и не гарантия обхода DPI. Код этого репозитория — сторонняя обёртка, **не официальная часть Telegram или TrafficGuard**.

## Возможности

- Интерактивный запрос FQDN и email, строгая проверка DNS A против публичного IPv4 сервера; проверка наличия AAAA.
- Проверка занятости TCP 80/443 и отказ от перезаписи работающих Caddy/tproxy на существующем сервере.
- Исходный официальный `tproxy-server/deploy/install.sh`: MTProxy, Caddy, HTTPS, systemd, локальный nftables firewall, подписывающий ключ, обновление MTProxy конфигурации.
- Принудительный Let's Encrypt ACME issuer в Caddyfile; **автообновление сертификата обеспечивает сам Caddy** (без cron и certbot).
- Один 128-битный случайный ключ, один профиль с `carrier_mode: https-lanes`, `max_sessions: 50`, `max_streams: 512`.
- `base_path` из upstream-инсталлятора, корректно закодированная WEB-ссылка и параметры ручного ввода в `/root/tproxy-links.txt` (0600).
- Отдельный этап TrafficGuard, только после согласия: сборка из официальных исходников, проверка SSH IP против `antiscanner.list`, сохранение firewall-backup, применение того же проверенного локального списка.

## Требования

- **Новый** выделенный VPS x86_64, Ubuntu 22.04+/24.04 или Debian 12+/13, systemd и root.
- Публичный IPv4 и домен с A-записью на этот IP. Не включайте CDN-проксирование. AAAA-запись допустима только при реально рабочем публичном IPv6 (`--allow-aaaa`).
- У хостера и в локальном firewall открыты входящие TCP **80** и **443**; сохранён работающий SSH-доступ.
- Доступ к GitHub, Go downloads, ACME/Let's Encrypt, Telegram.
- Желательно собственный небольшой, **реальный** сайт с `index.html`. При пустом пути установщик создаёт временную простую страницу, которую следует заменить перед публичным использованием.
- На сервере нет других сервисов, использующих Caddy/80/443. **Не запускайте поверх действующего Telegram-прокси**.

## Установка

После публикации проекта в GitHub:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/Uncleirvain/telegram-webproxy-pub.git
cd telegram-webproxy-pub
sudo bash install.sh
```

Если используете ZIP из релиза, распакуйте его, зайдите в папку и запустите `sudo bash install.sh`.

Скрипт спросит:

1. **Домен**, например `proxy.example.com`.
2. Email для Let's Encrypt.
3. Путь к директории сайта (или Enter для временной страницы).
4. Нужно ли **применить** TrafficGuard — default `N` для защиты удалённого SSH-доступа.
5. При согласии на TrafficGuard — публичный IP администратора (определяется из `SSH_CONNECTION`, можно указать вручную).

Пример с аргументами, включая включённый TrafficGuard:

```bash
sudo bash install.sh \
  --domain proxy.example.com \
  --email admin@example.com \
  --site-dir /root/my-site \
  --traffic-guard yes \
  --admin-ip 198.51.100.25
```

IP `198.51.100.25` здесь пример, его нужно заменить на **реальный IP, с которого вы подключаетесь по SSH**. Перед активацией TrafficGuard откройте резервную веб-консоль VPS у провайдера и сохраните вторую SSH-сессию. Фильтрация способна заблокировать *законного* пользователя, если он входит в список.

> Настройка с `--expected-ip IPV4` нужна, если автоопределение egress-IP не совпадает с публичным ingress-IP (например, специфический NAT). Отключать проверку DNS в штатном режиме нельзя. `--allow-aaaa` используйте лишь после внешней проверки IPv6.

## Что после установки

```bash
sudo cat /root/tproxy-links.txt             # НЕ публиковать, внутри secret
sudo systemctl status caddy mtproxy tproxy-server tproxy-firewall
curl -i http://127.0.0.1:8081/readyz
curl -I https://proxy.example.com/
```

Ссылка имеет вид `https://t.me/webproxy?server=...&secret=...`, но публичный `t.me/webproxy` может ещё не маршрутизировать эту ссылку: используйте WEB-совместимую сборку либо ручной ввод **сервера с base_path** и hex-secret из файла. Не следует вставлять URL в публичные issue и логи.

**Один secret можно использовать на разных устройствах**, однако отказать в доступе одному сотруднику при общей ссылке нельзя — придётся изменить secret всей группы. Лимиты регулируют сессии и потоки, а не число физических устройств.

## Статический сайт

Если был передан `--site-dir /root/my-site`, upstream копирует сайт в `/srv/tproxy-site`. Затем заменяйте файлы там; после обновления нужен `sudo systemctl restart tproxy-server`, потому что статика загружается в память при запуске. Caddy и MTProxy перезапускать не нужно.

Нельзя самостоятельно отделять в Caddy `/proxy` от статических файлов: по официальной схеме **все** запросы на 443 проходят через один `tproxy-server`.

## Сертификаты

Caddy автоматически запрашивает и продлевает сертификат у **Let's Encrypt** через ACME. Держите порты 80/443 и каталог `/var/lib/caddy` доступными. Отдельные `certbot`, cron или renewal timer не нужны.

Проверка сертификата:

```bash
echo | openssl s_client -connect proxy.example.com:443 -servername proxy.example.com 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

## TrafficGuard

При согласии скрипт **собирает** `dotX12/traffic-guard` из GitHub и вызывает:

```bash
sudo traffic-guard full \
  -u file:///var/lib/telegram-webproxy-pub/antiscanner.list
```

- Источник списка: `shadow-netlab/traffic-guard-lists/public/antiscanner.list`.
- Ручная проверка IP администратора выполняется до применения правил.
- Backups: `/var/lib/telegram-webproxy-pub/firewall-backups/`.
- Правила iptables/ipset сохраняются штатными механизмами TrafficGuard. Они сосуществуют с локальной nftables-защитой backend, которую ставит Telegram-инсталлятор.
- **Новые версии blocklist автоматически не подтягиваются.** Повторное применение нового файла необходимо проверять вручную. Защита от сканеров не равна защите от DDoS или DPI.

Удаление правил TrafficGuard (через консоль провайдера, если SSH заблокирован):

```bash
sudo traffic-guard uninstall --yes
```

Не восстанавливайте `iptables-save` вслепую поверх UFW без оценки других правил.

## Диагностика

```bash
systemctl is-active caddy mtproxy tproxy-server tproxy-firewall
curl -fsS http://127.0.0.1:8081/healthz
curl -fsS http://127.0.0.1:8081/readyz
journalctl -u caddy -u mtproxy -u tproxy-server --since '30 minutes ago' --no-pager
sudo nft list table inet tproxy_backend
sudo iptables -S INPUT
```

Проверяйте с другого устройства/сети TCP 2398, 8080, 8081, 8888 — они не должны быть публично доступны. `readyz` проверяет готовность сервера, но **не подтверждает работу реального клиента**.

Если протокол WebProxy в клиенте отсутствует, это проблема совместимости клиента, а не сертификата.

## Обновления и воспроизводимость

Обёртка не обновляет работающую установку и не содержит функцию автоматического удаления: это исключает незаметную ротацию ключа, base path или изменение Caddyfile. Сначала тестируйте любые обновления на новой VM. Конкретные upstream revisions записываются после установки в `/var/lib/telegram-webproxy-pub/*-revision.txt`.

По умолчанию загрузка идёт из `master` **на момент установки**. Для управляемого rollout можно задать точные проверенные SHA:

```bash
sudo TPROXY_REF=<tested-commit-sha> TRAFFIC_GUARD_REF=<tested-commit-sha> bash install.sh
```

Замените значения на реально проверенные SHA. Эти переменные не фиксированы по умолчанию, поэтому для production рекомендуется закрепить их в собственной версии репозитория и включить интеграционные тесты в чистой VM.

## Тесты

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
```

CI выполняет только статические и unit-проверки. **Установка, ACME, firewall и реальный Telegram-клиент не проходили end-to-end тест на удалённом VPS в рамках подготовки этого шаблона.** Перед массовой публикацией проведите пробную установку на изолированной VM с доступом через console.

## Исходные проекты и лицензии

- https://github.com/telegramdesktop/tproxy-server
- https://github.com/TelegramMessenger/MTProxy (используется upstream)
- https://github.com/dotX12/traffic-guard
- https://github.com/shadow-netlab/traffic-guard-lists
- https://caddyserver.com/docs/automatic-https

Обёртка распространяется по MIT. Исходные проекты не включены в архив, получаются при установке и сохраняют собственные лицензии.
