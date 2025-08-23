#!/usr/bin/env bash
set -euo pipefail

########################################################################
# Pterodactyl fast installer (Panel + Location + Node + DB Host + Wings)
# Usage:
#   ./install.sh <FQDN> <SSL true|false> <email> <username> <password> <wings true|false>
# Example:
#   ./install.sh 31.59.58.52 false info@vndel.com admin 'Strong#Pass1' true
########################################################################

dist="$(. /etc/os-release && echo "$ID")"
version="$(. /etc/os-release && echo "$VERSION_ID")"

# --------- step runner ----------
STEP=0
run() {
  STEP=$((STEP+1))
  local msg="$1"; shift
  echo "[$STEP] $msg"
  bash -c "$@" && echo ">>> passing step #$STEP" || { echo "xxx failed at step #$STEP: $msg"; exit 1; }
}
# --------------------------------

finish(){
  clear || true
  echo ""
  echo "[Vndel] [!] Panel installed."
  echo ""
}

require_arg(){ if [ -z "${!1:-}" ]; then echo "Missing arg: $1"; exit 1; fi; }

create_database_host_user() {
  echo ">>> Preparing Database Host MySQL user…"
  run "Create DB host user pterodactyl@'%' with same panel password" \
    "mariadb -u root -e \"CREATE USER IF NOT EXISTS 'pterodactyl'@'%' IDENTIFIED BY '${DBPASSWORD}';\""

  run "Grant privileges to DB host user" \
    "mariadb -u root -e \"GRANT ALL PRIVILEGES ON *.* TO 'pterodactyl'@'%' WITH GRANT OPTION;\""

  run "Flush privileges" \
    "mariadb -u root -e \"FLUSH PRIVILEGES;\""

  echo ">>> Database Host info (Panel → Admin → Databases → Hosts):"
  echo "    Name: game-dbhost"
  echo "    Host: ${FQDN}"
  echo "    Port: 3306"
  echo "    Username: pterodactyl"
  echo "    Password: ${DBPASSWORD}"
}

add_panel_database_host() {
  echo ">>> Adding Database Host into the Panel (Laravel-encrypted)…"
  run "Insert/Update database host in panel via Laravel Eloquent" \
    "( cd /var/www/pterodactyl && FQDN=\"$FQDN\" DBPASSWORD=\"$DBPASSWORD\" php -r '
      require \"vendor/autoload.php\";
      \$app = require \"bootstrap/app.php\";
      \$kernel = \$app->make(Illuminate\\Contracts\\Console\\Kernel::class);
      \$kernel->bootstrap();

      \$name     = \"game-dbhost\";
      \$host     = getenv(\"FQDN\") ?: \"127.0.0.1\";
      \$port     = 3306;
      \$username = \"pterodactyl\";
      \$password = getenv(\"DBPASSWORD\");

      \$attrs = [
        \"name\"          => \$name,
        \"host\"          => \$host,
        \"port\"          => \$port,
        \"username\"      => \$username,
        \"password\"      => \$password,
        \"max_databases\" => 0,
      ];

      \$model = null;
      if (class_exists(\"Pterodactyl\\\\Models\\\\DatabaseHost\")) {
        \$model = \"Pterodactyl\\\\Models\\\\DatabaseHost\";
      } elseif (class_exists(\"Pterodactyl\\\\Models\\\\Database\\\\Host\")) {
        \$model = \"Pterodactyl\\\\Models\\\\Database\\\\Host\";
      } else {
        fwrite(STDERR, \"DatabaseHost model not found.\\n\");
        exit(1);
      }

      \$model::updateOrCreate([\"host\"=>\$host,\"port\"=>\$port,\"username\"=>\$username], \$attrs);
      echo \"OK\\n\";
    ' )"
}

panel_conf(){
  echo "[++] cd /var/www/pterodactyl"
  cd /var/www/pterodactyl
  echo ">>> passing step (cd)"

  if [ "${SSL,,}" = "true" ]; then
    appurl="https://${FQDN}"
  else
    appurl="http://${FQDN}"
  fi

  FIRSTNAME="Vndel"
  LASTNAME="Creator"

  DBPASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | fold -w 16 | head -n 1)

  run "Create panel DB user (pterodactyl@127.0.0.1)" \
    "mariadb -u root -e \"CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DBPASSWORD}';\""

  run "Create panel database" \
    "mariadb -u root -e \"CREATE DATABASE IF NOT EXISTS panel;\""

  run "Grant privileges on panel.* to panel DB user" \
    "mariadb -u root -e \"GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;\""

  run "Flush privileges" \
    "mariadb -u root -e \"FLUSH PRIVILEGES;\""

  run "Panel environment setup" \
    "php artisan p:environment:setup --author=\"$EMAIL\" --url=\"$appurl\" --timezone=\"CET\" --telemetry=false --cache=\"redis\" --session=\"redis\" --queue=\"redis\" --redis-host=\"localhost\" --redis-pass=\"null\" --redis-port=\"6379\" --settings-ui=true"

  run "Panel DB environment binding" \
    "php artisan p:environment:database --host=\"127.0.0.1\" --port=\"3306\" --database=\"panel\" --username=\"pterodactyl\" --password=\"$DBPASSWORD\""

  run "Migrate & seed panel" \
    "php artisan migrate --seed --force"

  run "Create admin user (Vndel Creator)" \
    "php artisan p:user:make --email=\"$EMAIL\" --username=\"$USERNAME\" --name-first=\"$FIRSTNAME\" --name-last=\"$LASTNAME\" --password=\"$PASSWORD\" --admin=1"

  # DB Host: MySQL user + Panel record
  create_database_host_user
  add_panel_database_host

  # (باقي خطوات location/node/redis/nginx/wings تبقى مثل عندك)
  # …
}

panel_install(){
  run "apt update" "apt update"
  run "Install certbot" "apt install -y certbot"
  # (باقي خطوات التثبيت كما هي، بدون mariadb_repo_setup)
  # …
  echo "[++] cd /var/www/pterodactyl"
  cd /var/www/pterodactyl
  echo ">>> passing step (cd)"

  run "Download Panel tar.gz (latest)" \
    "curl -fsSL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"

  run "Extract Panel" \
    "tar -xzf panel.tar.gz"

  run "Fix storage/cache perms" \
    "chmod -R 755 storage/* bootstrap/cache/"

  run "Copy .env.example to .env if missing" \
    "cp -n .env.example .env"

  echo "⚙️ Composer is installing packages... please wait."
  run "Composer install (no-dev, optimize)" \
    "composer install --no-dev --optimize-autoloader --no-interaction"

  run "Generate APP_KEY" \
    "php artisan key:generate --force"

  panel_conf
}

# -------- Parse args --------
FQDN="${1:-}"; require_arg FQDN
SSL="${2:-}"; require_arg SSL
EMAIL="${3:-}"; require_arg EMAIL
USERNAME="${4:-}"; require_arg USERNAME
PASSWORD="${5:-}"; require_arg PASSWORD
WINGS="${6:-}"; require_arg WINGS

echo "Checking your OS.."
if { [ "$dist" = "ubuntu" ] && [ "$version" = "24.04" ]; } || { [ "$dist" = "debian" ] && { [ "$version" = "11" ] || [ "$version" = "12" ]; }; }; then
  echo "[ Vndel Hosting Automatic Setup ]"
  echo "FQDN (URL): $FQDN"
  echo "SSL: $SSL"
  echo "Email: $EMAIL"
  echo "Username: $USERNAME"
  echo "Name: Vndel Creator (auto)"
  echo "Wings install: $WINGS"
  echo "Starting automatic installation in 5 seconds…"
  sleep 5
  panel_install
else
  echo "Your OS, $dist $version, is not supported"
  exit 1
fi
