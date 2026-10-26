#!/usr/bin/env bash
# Maydan Al Hayy: one-command server install / update for Ubuntu 22.04 or 24.04.
#   curl -fsSL https://raw.githubusercontent.com/AxLo2001/maydan-server/main/install.sh | sudo bash
# Running it again updates the server and keeps all data and secrets.
set -euo pipefail

REPO="${MAYDAN_REPO:-https://github.com/AxLo2001/maydan-server.git}"
APP=/opt/maydan
ENVF=/etc/maydan.env
PSQL="${PSQL:-sudo -u postgres psql -v ON_ERROR_STOP=1 -q}"
G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
step(){ echo -e "\n${G}==> $*${N}"; }
warn(){ echo -e "${Y}!! $*${N}"; }
die(){ echo -e "${R}xx $*${N}"; exit 1; }

[ "$(id -u)" = 0 ] || die "شغل الأمر مع sudo (Run with sudo)."
. /etc/os-release 2>/dev/null || true
[ "${ID:-}" = ubuntu ] || warn "هذا السكربت مجرب على Ubuntu. نظامك: ${PRETTY_NAME:-unknown}"
export DEBIAN_FRONTEND=noninteractive

step "1/7 تحديث النظام وتثبيت الأدوات"
apt-get update -y
apt-get install -y curl git ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https postgresql openssl cron

step "2/7 تثبيت Node.js 22"
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
node -v

step "3/7 تثبيت Caddy (شهادة HTTPS تلقائية)"
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y && apt-get install -y caddy
fi

step "4/7 تنزيل كود الخادم"
if [ -d "$APP/.git" ]; then git -C "$APP" fetch -q origin && git -C "$APP" reset -q --hard origin/main
else rm -rf "$APP"; git clone -q "$REPO" "$APP"; fi
chmod -R a+rX "$APP"
(cd "$APP" && npm ci --omit=dev --silent 2>/dev/null || npm install --omit=dev --silent)

step "5/7 قاعدة البيانات"
if [ ! -f "$ENVF" ]; then
  DBPASS=$(openssl rand -hex 24); JWT=$(openssl rand -hex 48)
  PUBIP=$(curl -fsS4 --max-time 10 https://api.ipify.org || curl -fsS4 --max-time 10 https://ifconfig.me || true)
  [ -n "$PUBIP" ] || die "ما قدرنا نعرف عنوان IP الخادم."
  HOST="${MAYDAN_HOST:-$(echo "$PUBIP" | tr . -).sslip.io}"
  umask 077
  cat > "$ENVF" <<EOF
DATABASE_URL=postgresql://maydan:${DBPASS}@127.0.0.1:5432/maydan
JWT_SECRET=${JWT}
PORT=3000
HOST=${HOST}
DBPASS=${DBPASS}
EOF
fi
set -a
# shellcheck source=/dev/null
. "$ENVF"
set +a
systemctl enable --now postgresql >/dev/null 2>&1 || true
$PSQL -tc "select 1 from pg_roles where rolname='maydan'" | grep -q 1 || $PSQL -c "create role maydan login password '${DBPASS}'"
$PSQL -tc "select 1 from pg_database where datname='maydan'" | grep -q 1 || $PSQL -c "create database maydan"
$PSQL -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if; end \$\$;" -c "grant authenticated to maydan"
for f in 01-auth.sql 02-schema.sql 03-grants.sql 04-social.sql 05-challenges.sql; do $PSQL -d maydan -f "$APP/sql/$f" 2>&1 | grep -v "NOTICE\|already exists\|does not exist, skipping" || true; done
$PSQL -d maydan -c "grant usage on schema auth to maydan; grant execute on function auth.sign_up(text,text,text), auth.sign_in(text,text) to maydan; grant select, insert, delete on auth.refresh_tokens to maydan; grant select on auth.users to maydan;"

step "6/7 تشغيل الخادم"
cat > /etc/systemd/system/maydan.service <<EOF
[Unit]
Description=Maydan Al Hayy API
After=network.target postgresql.service
[Service]
EnvironmentFile=$ENVF
WorkingDirectory=$APP
ExecStart=$(command -v node) $APP/server.js
Restart=always
RestartSec=3
User=nobody
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
chmod 600 "$ENVF"; chown root:root "$ENVF"   # systemd reads it as root; the service itself runs as nobody
systemctl daemon-reload && systemctl enable maydan >/dev/null 2>&1 && systemctl restart maydan

for p in 80 443; do
  if ss -ltnp 2>/dev/null | grep -q ":$p .*" && ! ss -ltnp 2>/dev/null | grep ":$p " | grep -q caddy; then
    warn "المنفذ $p مستخدم من برنامج ثاني (مثل nginx أو apache). أوقفه أو أخبرنا عشان نعدل الإعدادات."
  fi
done
cat > /etc/caddy/Caddyfile <<EOF
${HOST} {
  encode gzip
  reverse_proxy 127.0.0.1:${PORT}
  header -Server
}
EOF
systemctl enable caddy >/dev/null 2>&1; systemctl reload caddy 2>/dev/null || systemctl restart caddy
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow 22/tcp >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi

step "7/7 النسخ الاحتياطي اليومي وأداة كلمة المرور"
mkdir -p /var/backups/maydan && chown postgres:postgres /var/backups/maydan && chmod 700 /var/backups/maydan
cat > /etc/cron.d/maydan-backup <<'EOF'
# daily database backup at 03:30, keep 14 days
30 3 * * * postgres pg_dump -Fc maydan > /var/backups/maydan/maydan-$(date +\%F).dump && find /var/backups/maydan -name '*.dump' -mtime +14 -delete
EOF
cat > /usr/local/bin/maydan-password <<'EOF'
#!/usr/bin/env bash
# usage: sudo maydan-password user@email.com NewPassword123
[ $# -eq 2 ] || { echo "usage: sudo maydan-password EMAIL NEW_PASSWORD"; exit 1; }
[ ${#2} -ge 8 ] || { echo "password must be at least 8 characters"; exit 1; }
r=$(sudo -u postgres psql -d maydan -tAc "select auth.set_password('$(printf %s "$1" | sed "s/'/''/g")', '$(printf %s "$2" | sed "s/'/''/g")')")
[ "$r" = t ] && echo "Password changed for $1" || echo "No account with email $1"
EOF
chmod 755 /usr/local/bin/maydan-password

sleep 3
ok=$(curl -fsS --max-time 5 http://127.0.0.1:${PORT}/health || true)
[ -n "$ok" ] || { journalctl -u maydan -n 30 --no-pager; die "الخادم ما اشتغل. أرسل الرسائل اللي فوق."; }
echo -e "\n${G}تم التثبيت بنجاح${N}"
echo "رابط الخادم (أرسله لـ Claude):"
echo -e "${G}    https://${HOST}${N}"
echo "أول مرة، الشهادة تاخذ دقيقة تقريباً. جربه من الجوال: https://${HOST}/health"
