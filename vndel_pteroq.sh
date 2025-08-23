#!/usr/bin/env bash
set -uo pipefail

########################################################################
# Pterodactyl fast installer (Panel + Location + Node + DB Host + Wings)
# Usage:
#   ./install.sh <FQDN> <SSL true|false> <email> <username> <password> <wings true|false>
# Example:
#   ./install.sh 93.113.180.194 false info@vndel.com admin 'Strong#Pass1' true
########################################################################

dist="$(. /etc/os-release && echo "$ID")"
version="$(. /etc/os-release && echo "$VERSION_ID")"

finish(){
  ### clear || true
  echo ""
  echo "[Vndel] [!] Panel installed successfully."
  echo ""
}

require_arg(){ if [ -z "${!1:-}" ]; then echo "Missing arg: $1"; exit 1; fi; }

create_database_host_user() {
  # user/password لِـ DB Host (خارجي) — نفس باسورد البانل DBPASSWORD
  mariadb -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'%' IDENTIFIED BY '${DBPASSWORD}';"
  mariadb -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'pterodactyl'@'%' WITH GRANT OPTION;"
  mariadb -u root -e "FLUSH PRIVILEGES;"
}

add_panel_database_host() {
  # إضافة Database Host داخل البانل (يحفظ مشفّرًا عبر Eloquent/Mutators)
  (
    cd /var/www/pterodactyl || exit 1
    FQDN="$FQDN" DBPASSWORD="$DBPASSWORD" php -r '
      require "vendor/autoload.php";
      $app = require "bootstrap/app.php";
      $kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
      $kernel->bootstrap();

      $model = class_exists("Pterodactyl\\Models\\DatabaseHost")
        ? "Pterodactyl\\Models\\DatabaseHost"
        : (class_exists("Pterodactyl\\Models\\Database\\Host")
            ? "Pterodactyl\\Models\\Database\\Host" : null);

      if (!$model) { fwrite(STDERR, "DatabaseHost model not found.\n"); exit(1); }

      $attrs = [
        "name"          => "game-dbhost",
        "host"          => getenv("FQDN"),
        "port"          => 3306,
        "username"      => "pterodactyl",
        "password"      => getenv("DBPASSWORD"),
        "max_databases" => 0,
      ];

      $model::updateOrCreate(
        ["host"=>$attrs["host"],"port"=>$attrs["port"],"username"=>$attrs["username"]],
        $attrs
      );
      echo "Database Host added.\n";
    '
  )
}

panel_conf(){
  cd /var/www/pterodactyl || exit 1

  if [ "${SSL,,}" = "true" ]; then
    appurl="https://${FQDN}"
  else
    appurl="http://${FQDN}"
  fi

  FIRSTNAME="Vndel"
  LASTNAME="Creator"
  DBPASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | fold -w 16 | head -n 1)

  echo ">>> Configuring MariaDB (panel user/db)…"
  mariadb -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DBPASSWORD}';"
  mariadb -u root -e "CREATE DATABASE IF NOT EXISTS panel;"
  mariadb -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
  mariadb -u root -e "FLUSH PRIVILEGES;"

  echo ">>> Artisan environment setup…"
  php artisan p:environment:setup \
    --author="$EMAIL" --url="$appurl" --timezone="CET" --telemetry=false \
    --cache="redis" --session="redis" --queue="redis" \
    --redis-host="localhost" --redis-pass="null" --redis-port="6379" \
    --settings-ui=true || true

  php artisan p:environment:database \
    --host="127.0.0.1" --port="3306" --database="panel" \
    --username="pterodactyl" --password="$DBPASSWORD" || true

  php artisan migrate --seed --force || true

  php artisan p:user:make \
    --email="$EMAIL" --username="$USERNAME" \
    --name-first="$FIRSTNAME" --name-last="$LASTNAME" \
    --password="$PASSWORD" --admin=1 || true

  # ===== DB Host (خارجي) =====
  create_database_host_user
  add_panel_database_host

  # ===== Location =====
  LOC_SHORT="dc1"
  LOC_LONG="Default Datacenter"
  php artisan p:location:make --short="$LOC_SHORT" --long="$LOC_LONG" || true
  LOCATION_ID=$(mariadb -u root -sN -e "USE panel; SELECT id FROM locations WHERE short='${LOC_SHORT}' LIMIT 1;")
  echo ">>> Location=$LOCATION_ID"

  # ===== Node =====
  NODE_NAME="auto-node"
  NODE_DESC="Auto-created node"
  NODE_SCHEME="$([ "${SSL,,}" = "true" ] && echo https || echo http)"

  php artisan p:node:make \
    --name="$NODE_NAME" \
    --description="$NODE_DESC" \
    --locationId="$LOCATION_ID" \
    --fqdn="$FQDN" \
    --public=1 \
    --scheme="$NODE_SCHEME" \
    --proxy=0 \
    --maintenance=0 \
    --maxMemory=2500000 \
    --overallocateMemory=-1 \
    --maxDisk=2500000 \
    --overallocateDisk=-1 \
    --uploadSize=100 \
    --daemonListeningPort=8080 \
    --daemonSFTPPort=2022 \
    --daemonBase="/var/lib/pterodactyl/volumes" || true

  NODE_ID=$(mariadb -u root -sN -e "USE panel; SELECT id FROM nodes WHERE fqdn='${FQDN}' OR name='${NODE_NAME}' ORDER BY id ASC LIMIT 1;")
  echo ">>> Node=$NODE_ID"

  # ===== Wings (تثبيت + تهيئة + config.yml) =====
  if [ "${WINGS,,}" = "true" ]; then
    echo ">>> Installing Wings + Docker…"
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker

    mkdir -p /etc/pterodactyl
    apt-get -y install curl tar unzip

    ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && WARCH="amd64" || WARCH="arm64"
    curl -fsSL -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WARCH}"
    chmod +x /usr/local/bin/wings

    curl -fsSL -o /etc/systemd/system/wings.service \
      "https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/wings.service"
    systemctl daemon-reload
    systemctl enable --now wings || true  # قد يفشل حتى توليد config.yml — عادي

    # توليد config.yml حسب أوامر Artisan المتاحة
    if [ -n "${NODE_ID:-}" ]; then
      if php artisan list | grep -q "p:node:configuration"; then
        php artisan p:node:configuration --node="$NODE_ID" --output="/etc/pterodactyl/config.yml" || true
      elif php artisan list | grep -q "p:wings:configuration"; then
        php artisan p:wings:configuration --node="$NODE_ID" --output="/etc/pterodactyl/config.yml" || true
      else
        echo "(!) No artisan config generator found. Copy config from Panel → Nodes → Configuration."
      fi
      systemctl restart wings || true
      systemctl status wings --no-pager || true
    fi
  fi

  # ===== Services & Nginx =====
  chown -R www-data:www-data /var/www/pterodactyl/*
  curl -fsSL -o /etc/systemd/system/pteroq.service \
    https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/pteroq.service
  (crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -
  systemctl enable --now redis-server
  systemctl enable --now pteroq.service

  rm -rf /etc/nginx/sites-enabled/default
  if [ "${SSL,,}" = "true" ]; then
    curl -fsSL -o /etc/nginx/sites-enabled/pterodactyl.conf \
      https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/pterodactyl-nginx-ssl.conf
    sed -i -e "s@<domain>@${FQDN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
    systemctl stop nginx || true
    certbot certonly --standalone -d "$FQDN" --staple-ocsp --no-eff-email -m "$EMAIL" --agree-tos
    systemctl start nginx
  else
    curl -fsSL -o /etc/nginx/sites-enabled/pterodactyl.conf \
      https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/pterodactyl-nginx.conf
    sed -i -e "s@<domain>@${FQDN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
    systemctl restart nginx
  fi

  finish
}

panel_install(){
  echo ">>> Installing prerequisites..."
  apt update
  # بدون مستودعات خارجية لـ MariaDB — من apt مباشرة
  apt install -y certbot mariadb-server tar unzip git redis-server nginx \
                 php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip}
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

  # تحسين توافق MariaDB (لو كان السطر موجود)
  sed -i 's/character-set-collations = utf8mb4=uca1400_ai_ci/character-set-collations = utf8mb4=utf8mb4_general_ci/' \
    /etc/mysql/mariadb.conf.d/50-server.cnf 2>/dev/null || true
  systemctl restart mariadb

  echo ">>> Preparing Pterodactyl panel..."
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl || exit 1
  curl -fsSL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/
  cp -n .env.example .env

  echo "⚙️ Running composer install (this may take a few minutes)..."
  composer install --no-dev --optimize-autoloader --no-interaction || true

  php artisan key:generate --force || true

  panel_conf
}

# -------- Parse args --------
FQDN="${1:-}"; require_arg FQDN
SSL="${2:-}"; require_arg SSL
EMAIL="${3:-}"; require_arg EMAIL
USERNAME="${4:-}"; require_arg USERNAME
PASSWORD="${5:-}"; require_arg PASSWORD
WINGS="${6:-}"; require_arg WINGS

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
