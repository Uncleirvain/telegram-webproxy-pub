#!/usr/bin/env bash
# Interactive installer for a fresh VPS. Does not support in-place upgrades.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TPROXY_REPO='https://github.com/telegramdesktop/tproxy-server.git'
GUARD_REPO='https://github.com/dotX12/traffic-guard.git'
BLOCKLIST_URL='https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list'
TPROXY_REF="${TPROXY_REF:-master}"
TRAFFIC_GUARD_REF="${TRAFFIC_GUARD_REF:-master}"
TPROXY_DIR=/opt/telegram-webproxy-upstream
GUARD_DIR=/opt/traffic-guard
STATE_DIR=/var/lib/telegram-webproxy-oneclick
DOMAIN=''
EMAIL=''
SITE_DIR=''
EXPECTED_IP=''
ADMIN_IP=''
ALLOW_AAAA=0
GUARD_MODE=ask
PHASE='preflight'

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mВНИМАНИЕ: %s\033[0m\n' "$*" >&2; }
die() { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2016
trap 'printf "\nОшибка на этапе: %s (строка %s). Проверь вывод выше.\n" "$PHASE" "$LINENO" >&2' ERR

usage() {
  cat <<'EOF'
Использование: sudo ./install.sh [параметры]
  --domain DOMAIN             FQDN домена (иначе интерактивный вопрос)
  --email EMAIL               Контакт Let's Encrypt
  --site-dir DIR              Готовый статический сайт с index.html
  --expected-ip IPV4          Публичный IPv4 VPS (если autodetect не подходит)
  --admin-ip IP               IP админа для проверки списка TrafficGuard
  --allow-aaaa                Разрешить AAAA при самостоятельной проверке IPv6
  --traffic-guard ask|yes|no  Согласие на применение firewall-правил (по умолчанию ask)
  -h, --help                  Помощь
Переменные для закрепления upstream: TPROXY_REF, TRAFFIC_GUARD_REF.
EOF
}

while (( $# )); do
  case "$1" in
    --domain|--email|--site-dir|--expected-ip|--admin-ip|--traffic-guard)
      (( $# >= 2 )) || die "У опции $1 отсутствует значение"
      case "$1" in
        --domain) DOMAIN="$2" ;;
        --email) EMAIL="$2" ;;
        --site-dir) SITE_DIR="$2" ;;
        --expected-ip) EXPECTED_IP="$2" ;;
        --admin-ip) ADMIN_IP="$2" ;;
        --traffic-guard) GUARD_MODE="$2" ;;
      esac
      shift 2 ;;
    --allow-aaaa) ALLOW_AAAA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

(( EUID == 0 )) || die 'Запусти от root: sudo ./install.sh'
[[ $(uname -m) == 'x86_64' ]] || die 'Для stock MTProxy нужен Linux x86_64'
[[ -f /etc/os-release ]] || die 'Неизвестная ОС'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || die 'Поддерживаются Ubuntu и Debian'
OS_MAJOR="${VERSION_ID%%.*}"
[[ "$OS_MAJOR" =~ ^[0-9]+$ ]] || die 'Не удалось определить версию ОС'
if [[ "$ID" == ubuntu ]]; then
  (( OS_MAJOR >= 22 )) || die 'Нужна Ubuntu 22.04 или новее'
else
  (( OS_MAJOR >= 12 )) || die 'Нужен Debian 12 или новее'
fi
[[ ${GUARD_MODE} == ask || ${GUARD_MODE} == yes || ${GUARD_MODE} == no ]] || die '--traffic-guard должен быть ask, yes или no'
[[ -d /run/systemd/system ]] || die 'Нужен Linux с запущенным systemd'

if [[ -e /etc/tproxy-server/config.json || -e /etc/systemd/system/tproxy-server.service ]]; then
  die 'На сервере уже есть tproxy-server. Этот скрипт предназначен только для чистого VPS.'
fi
if [[ -e /etc/caddy/Caddyfile || -e /etc/systemd/system/caddy.service ]]; then
  die 'Уже существует Caddy. Установка могла бы перезаписать конфигурацию. Используй чистый VPS.'
fi

info 'Подготовка параметров'
if [[ -z "$DOMAIN" ]]; then
  read -r -p 'Домен (например proxy.example.com): ' DOMAIN
fi
if [[ -z "$EMAIL" ]]; then
  read -r -p "Email для Let's Encrypt: " EMAIL
fi
# Client format and upstream installer accept lowercase ASCII FQDN.
[[ "$DOMAIN" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ && "$DOMAIN" == *.* ]] || die 'Домен: только lowercase ASCII, нужен FQDN'
[[ "$EMAIL" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'Некорректный email'

if [[ -z "$SITE_DIR" ]]; then
  read -r -p 'Путь к папке сайта с index.html (Enter — временная страница): ' SITE_DIR
fi

# This script must be executed from a full checkout/archive, not downloaded alone.
for helper in check-domain.py check-blocklist.py make-link.py; do
  [[ -f "$PROJECT_DIR/scripts/$helper" ]] || die "Отсутствует scripts/$helper. Скачай весь репозиторий или используй bootstrap.sh."
done

PHASE='dependencies'
info 'Базовые зависимости'
apt-get update
apt-get install -y --no-install-recommends git curl ca-certificates openssl python3 iproute2 iptables ipset

PHASE='dns-check'
info 'Проверка домена и публичного IPv4'
if [[ -z "$EXPECTED_IP" ]]; then
  for endpoint in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
    EXPECTED_IP="$(curl --fail --silent --show-error --location --ipv4 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]')" || EXPECTED_IP=''
    [[ -n "$EXPECTED_IP" ]] && break
  done
fi
[[ -n "$EXPECTED_IP" ]] || die 'Не удалось определить публичный IPv4. Укажи --expected-ip.'
DNS_ARGS=()
if (( ALLOW_AAAA )); then DNS_ARGS+=(--allow-aaaa); fi
python3 "$PROJECT_DIR/scripts/check-domain.py" "$DOMAIN" "$EXPECTED_IP" "${DNS_ARGS[@]}"

if ss -H -lnt | awk '{print $4}' | grep -Eq '(^|:)(80|443)$'; then
  die 'Порт 80 или 443 уже занят. Этот инсталлятор предназначен для чистого VPS.'
fi
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  warn 'UFW активен. Добавляю только 80/443, правила SSH не меняю.'
  ufw allow 80/tcp
  ufw allow 443/tcp
fi
warn 'У провайдера тоже должны быть разрешены входящие TCP 80/443, а SSH должен оставаться доступным.'

PHASE='site'
if [[ -z "$SITE_DIR" ]]; then
  SITE_DIR="$STATE_DIR/temporary-site"
  install -d -m 0755 "$SITE_DIR"
  # Not a production camouflage site. The user is explicitly warned to replace it.
  cat > "$SITE_DIR/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${DOMAIN}</title></head>
<body><main><h1>${DOMAIN}</h1><p>Welcome.</p></main></body>
</html>
EOF
  chmod 0644 "$SITE_DIR/index.html"
  warn 'Создана ВРЕМЕННАЯ страница. Перед публикацией замени её полноценным собственным сайтом в /srv/tproxy-site.'
fi
[[ -d "$SITE_DIR" && -f "$SITE_DIR/index.html" && -r "$SITE_DIR/index.html" ]] || die 'Нужен каталог сайта с читаемым index.html'
SITE_DIR="$(cd "$SITE_DIR" && pwd -P)"

PHASE='upstream'
info 'Загрузка официального tproxy-server'
[[ ! -e "$TPROXY_DIR" ]] || die "Уже существует $TPROXY_DIR, остановлено во избежание перезаписи."
git clone --quiet "$TPROXY_REPO" "$TPROXY_DIR"
git -C "$TPROXY_DIR" checkout --quiet "$TPROXY_REF"
install -d -m 0700 "$STATE_DIR"
git -C "$TPROXY_DIR" rev-parse HEAD > "$STATE_DIR/tproxy-revision.txt"

# The upstream Caddyfile is used as-is except for an explicit Let's Encrypt ACME issuer.
python3 - "$TPROXY_DIR/deploy/Caddyfile" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]); s = p.read_text()
needle = '{$TPROXY_HOSTNAME} {\n'
if s.count(needle) != 1:
    raise SystemExit('Неожиданный формат upstream Caddyfile: патч Let\'s Encrypt не применён')
issuer = ('\ttls {\n\t\tissuer acme {\n'
          '\t\t\tdir https://acme-v02.api.letsencrypt.org/directory\n'
          '\t\t}\n\t}\n')
p.write_text(s.replace(needle, needle + issuer))
PY

PHASE='official-install'
info 'Запуск официального установщика (1 secret, Caddy, MTProxy, systemd)'
SECRET="$(openssl rand -hex 16)"
# Secret only enters upstream stdin; never appears in process arguments or public logs.
# Do not expose the secret or bearer URL in the upstream installer's terminal output.
printf '%s\n' "$SECRET" | "$TPROXY_DIR/deploy/install.sh" \
  --hostname "$DOMAIN" \
  --email "$EMAIL" \
  --site-dir "$SITE_DIR" \
  --base-path none \
  | sed -u -E '/^(Internal mtproxy secret:|Proxy secret:|Proxy link:)/d'
unset SECRET

PHASE='https-lanes'
info 'Режим https-lanes и лимиты для одного общего пользователя'
python3 - <<'PY'
import json, os, stat, tempfile
from pathlib import Path
p = Path('/etc/tproxy-server/profiles.json')
data = json.loads(p.read_text())
assert len(data['profiles']) == 1, 'Ожидается ровно один профиль'
profile = data['profiles'][0]
profile['carrier_mode'] = 'https-lanes'
profile['limits'] = {'max_sessions': 50, 'max_streams': 512}
st = p.stat()
fd, tmp = tempfile.mkstemp(prefix='.profiles-', dir=p.parent)
try:
    with os.fdopen(fd, 'w') as out:
        json.dump(data, out, indent=2)
        out.write('\n')
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, stat.S_IMODE(st.st_mode))
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
/usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json \
  -profiles-file /etc/tproxy-server/profiles.json -check
systemctl restart tproxy-server

PHASE='verify'
info 'Проверка сервисов и HTTPS'
for service in mtproxy tproxy-server caddy tproxy-firewall; do
  systemctl is-active --quiet "$service" || die "Не запущен сервис: $service"
done
READY=0
for (( i=0; i<30; i++ )); do
  if curl -fsS -o /dev/null --connect-timeout 2 http://127.0.0.1:8081/readyz; then READY=1; break; fi
  sleep 1
done
(( READY )) || die 'tproxy-server не готов (readyz). Смотри journalctl -u tproxy-server -u mtproxy.'
HTTPS=0
for (( i=0; i<20; i++ )); do
  if curl -fsS --connect-timeout 3 --max-time 8 -o /dev/null "https://$DOMAIN/"; then HTTPS=1; break; fi
  sleep 3
done
(( HTTPS )) || die "HTTPS не отвечает: проверь DNS, firewall VPS и journalctl -u caddy. Базовые сервисы уже установлены."
python3 "$PROJECT_DIR/scripts/make-link.py"

# TrafficGuard is opt-in because it can block legitimate clients or SSH.
if [[ "$GUARD_MODE" == ask ]]; then
  echo
  warn 'TrafficGuard блокирует IP по внешнему списку. Возможна потеря доступа по SSH.'
  read -r -p 'Установить И ПРИМЕНИТЬ TrafficGuard? [y/N]: ' agree
  if [[ "$agree" =~ ^[yY]([eE][sS])?$ ]]; then GUARD_MODE=yes; else GUARD_MODE=no; fi
fi

if [[ "$GUARD_MODE" == yes ]]; then
  PHASE='traffic-guard-preflight'
  info 'Защита SSH перед применением TrafficGuard'
  if [[ -z "$ADMIN_IP" && -n "${SSH_CONNECTION:-}" ]]; then ADMIN_IP="${SSH_CONNECTION%% *}"; fi
  if [[ -z "$ADMIN_IP" && -n "${SSH_CLIENT:-}" ]]; then ADMIN_IP="${SSH_CLIENT%% *}"; fi
  if [[ -z "$ADMIN_IP" ]]; then
    read -r -p 'Публичный IP администратора, с которого подключаешься по SSH: ' ADMIN_IP
  fi
  [[ -n "$ADMIN_IP" ]] || die 'Нужен IP администратора; TrafficGuard НЕ применён.'
  install -d -m 0700 "$STATE_DIR/firewall-backups"
  BACKUP="$STATE_DIR/firewall-backups/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$BACKUP"
  iptables-save > "$BACKUP/iptables.v4"
  ip6tables-save > "$BACKUP/iptables.v6"
  nft list ruleset > "$BACKUP/nft.ruleset" || true
  curl --fail --silent --show-error --location --max-time 30 \
    "$BLOCKLIST_URL" -o "$STATE_DIR/antiscanner.list"
  chmod 0600 "$STATE_DIR/antiscanner.list"
  python3 "$PROJECT_DIR/scripts/check-blocklist.py" "$STATE_DIR/antiscanner.list" "$ADMIN_IP"

  # TrafficGuard may configure/reload UFW if the package is installed even when inactive.
  # Ensure we do not activate UFW without explicitly allowing this SSH connection.
  if command -v ufw >/dev/null 2>&1; then
    SSH_PORT="${SSH_CONNECTION:-}"
    SSH_PORT="$(awk '{print $4}' <<< "$SSH_PORT")"
    if [[ -z "$SSH_PORT" ]]; then
      read -r -p 'TCP-порт SSH на этом сервере [22]: ' SSH_PORT
      SSH_PORT="${SSH_PORT:-22}"
    fi
    [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || \
      die 'Некорректный TCP-порт SSH; TrafficGuard не применён'
    if ! ufw status | grep -q 'Status: active'; then
      warn "UFW неактивен, подготовлю разрешения для SSH:$SSH_PORT и HTTP(S) перед его возможной активацией."
      ufw allow "$SSH_PORT/tcp"
      ufw allow 80/tcp
      ufw allow 443/tcp
    fi
  fi

  PHASE='traffic-guard-build'
  info 'Сборка TrafficGuard из официального исходного кода'
  [[ ! -e "$GUARD_DIR" ]] || die "Уже существует $GUARD_DIR. TrafficGuard не применён."
  git clone --quiet "$GUARD_REPO" "$GUARD_DIR"
  git -C "$GUARD_DIR" checkout --quiet "$TRAFFIC_GUARD_REF"
  git -C "$GUARD_DIR" rev-parse HEAD > "$STATE_DIR/traffic-guard-revision.txt"
  GO_BIN=''
  if [[ -x /opt/go1.26.5/bin/go ]]; then
    GO_BIN=/opt/go1.26.5/bin/go
  elif command -v go >/dev/null 2>&1 && python3 - "$(go version | awk '{print $3}')" <<'PY'
import re, sys
match = re.fullmatch(r'go(\d+)\.(\d+)(?:\.(\d+))?.*', sys.argv[1])
raise SystemExit(0 if match and tuple(map(int, (match.group(1), match.group(2), match.group(3) or '0'))) >= (1,25,3) else 1)
PY
  then
    GO_BIN="$(command -v go)"
  else
    warn 'Системная версия Go слишком старая. Скачиваю проверенный Go 1.26.5.'
    TMP_GO="$(mktemp -d)"
    curl -fLsS 'https://go.dev/dl/go1.26.5.linux-amd64.tar.gz' -o "$TMP_GO/go.tar.gz"
    echo '5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053  '"$TMP_GO/go.tar.gz" | sha256sum -c -
    tar -xzf "$TMP_GO/go.tar.gz" -C "$TMP_GO"
    [[ ! -e /opt/go1.26.5 ]] || die '/opt/go1.26.5 уже занят другим файлом/каталогом'
    mv "$TMP_GO/go" /opt/go1.26.5
    rm -rf "$TMP_GO"
    GO_BIN=/opt/go1.26.5/bin/go
  fi
  (cd "$GUARD_DIR" && "$GO_BIN" test ./... && "$GO_BIN" build -trimpath -o /usr/local/bin/traffic-guard ./cmd)
  chmod 0755 /usr/local/bin/traffic-guard

  PHASE='traffic-guard-apply'
  info 'Применение предварительно проверенного блок-листа TrafficGuard'
  # Serve exactly the downloaded, validated file to TrafficGuard over localhost.
  # Older TrafficGuard builds reject file:// URLs, and downloading the public
  # URL again would introduce a mismatch between checked and applied content.
  python3 - "$STATE_DIR/antiscanner.list" <<'PY_LOCAL_LIST'
import functools
import http.server
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading

source = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='tproxy-guard-list-') as temp:
    directory = pathlib.Path(temp)
    shutil.copyfile(source, directory / 'antiscanner.list')

    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    handler = functools.partial(QuietHandler, directory=str(directory))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f'http://127.0.0.1:{server.server_port}/antiscanner.list'
        subprocess.run(['/usr/local/bin/traffic-guard', 'full', '-u', url], check=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
PY_LOCAL_LIST

  V4_COUNT="$(ipset list SCANNERS-BLOCK-V4 | awk '/Number of entries:/ {print $4}')"
  V6_COUNT="$(ipset list SCANNERS-BLOCK-V6 | awk '/Number of entries:/ {print $4}')"
  [[ "$V4_COUNT" =~ ^[0-9]+$ && "$V6_COUNT" =~ ^[0-9]+$ ]] || \
    die 'TrafficGuard: не удалось определить количество заблокированных сетей'
  if (( V4_COUNT + V6_COUNT == 0 )); then
    warn 'TrafficGuard создал пустые ipset-наборы. Правила требуют проверки.'
    die 'TrafficGuard: блок-лист не применён — смотри логи выше; перед повторным запуском удали неполную установку'
  fi

  info "TrafficGuard: загружено IPv4=$V4_COUNT, IPv6=$V6_COUNT"
  info 'TrafficGuard применён. Проверь SSH со второй сессии!'
else
  info 'TrafficGuard не активирован; его можно подключить позднее по README.'
fi

PHASE='finished'
info 'Готово'
printf 'Сайт:           https://%s/\n' "$DOMAIN"
printf 'Режим:          https-lanes\n'
printf 'Доступы:        /root/tproxy-links.txt (только root)\n'
printf 'Сертификат:     Caddy + Let\x27s Encrypt, автоматическое продление\n'
printf 'TrafficGuard:   %s\n' "$GUARD_MODE"
printf 'Ревизии:        %s\n' "$STATE_DIR"
printf '\nНе публикуй URL и secret в GitHub. Проверь подключение с WEB-совместимого Telegram-клиента.\n'
