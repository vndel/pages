#!/usr/bin/env bash
set -euo pipefail

########################################################################
# Pterodactyl fast installer (Panel + Location + Node + DB Host + Wings)
# Usage:
#   ./install.sh <FQDN> <SSL true|false> <email> <username> <password> <wings true|false>
########################################################################

dist="$(. /etc/os-release && echo "$ID")"
version="$(. /etc/os-release && echo "$VERSION_ID")"

finish(){
  clear || true
  echo ""
  echo "[Vndel] [!] Panel installed."
  echo ""
}

require_arg(){ if [ -z "${!1:-}" ]; then echo "Missing arg: $1"; exit 1; fi; }

create_database_host_user() {
  echo ">>> Preparing Database Host MySQL user…"
  mariadb -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'%' IDENTIFIED BY '${DBPASSWORD}';"
  mariadb -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'pterodactyl'@'%' WITH GRANT OPTION;"
  mariadb -u root -e "FLUSH PRIVILEGES;"

  echo ">>> Database Host info (Panel → Admin → Databases → Hosts):"
  echo "    Name: game-dbhost"
  echo "    Host: ${FQDN}"
  echo "    Port: 3306"
  echo "    Username: pterodactyl"
  echo "    Password: ${DBPASSWORD}"
}

add_panel_database_host() {
  echo ">>> Adding Database Host into the Panel (Laravel-encrypted)…"
  (
    cd /var/www/pterodactyl
    FQDN="$FQDN" DBPASSWORD="$DBPASSWORD" php -r '
      require "vendor/autoload.php";
      $app = require "bootstrap/app.php";
      $kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
      $kernel->bootstrap();

      $name     = "game-dbhost";
      $host     = getenv("FQDN") ?: "127.0.0.1";
      $port     = 3306;
      $username = "pterodactyl";
      $password = getenv("DBPASSWORD");

      $attrs = [
        "name"          => $name,
        "host"          => $host,
        "port"          => $port,
        "username"      => $username,
        "password"      => $password,
        "max_databases" => 0,
      ];

      if (class_exists("Pterodactyl\\Models\\DatabaseHost")) {
        $model = "Pterodactyl\\Models\\DatabaseHost";
      } elseif (class_exists("Pterodactyl\\Models\\Database\\Host")) {
        $model = "Pterodactyl\\Models\\Database\\Host";
      } else {
        fwrite(STDERR, "DatabaseHost model not found.\n");
        exit(1);
      }

      $model::updateOrCreate(
        ["host"=>$host,"port"=>$port,"username"=>$username],
        $attrs
      );
      echo "OK\n";
    '
  )
}

panel_conf(){
  cd /var/www/pterodactyl

  if [ "${SSL,,}" = "true" ]; then
    appurl="https://${FQDN}"
  else
    appurl="http://${FQDN}"
  fi

  FIRSTNAME="Vndel"
  LASTNAME="Creator"
  DBPASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | fold -w 16 | head -n 1)

  mariadb -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DBPASSWORD}';"
  mariadb -u root -e "CREATE DATABASE IF NOT EXISTS panel;"
  mariadb -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
  mariadb -u root -e "FLUSH PRIVILEGES;"

  php artisan p:environment:setup \
    --author="$EMAIL" --url="$appurl" --timezone="CET" --telemetry=false \
    --cache="redis" --session="redis" --queue="redis" \
    --redis-host="localhost" --redis-pass="null" --redis-port="6379" \
    --settings-ui=true

  php artisan p:environment:database \
    --host="127.0.0.1" --port="3306" --database="panel" \
    --username="pterodactyl" --password="$DBPASSWORD"

  php artisan migrate --seed --force

  php artisan p:user:make \
    --email="$EMAIL" --username="$USERNAME" \
    --name-first="$FIRSTNAME" --name-last="$LASTNAME" \
    --password="$PASSWORD" --admin=1

  # DB Host: MySQL user + Panel record
  create_database_host_user
  add_panel_database_host

  # باقي خطوات Location / Node / Wings / Nginx زي ما كانت
  # ...
}

panel_install(){
  apt update
  apt install -y certbot

  if  [ "$dist" = "ubuntu" ] && [ "$version" = "24.04" ]; then
    apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor --batch --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list
    apt update
    add-apt-repository "deb http://archive.ubuntu.com/ubuntu $(lsb_release -sc) universe" -y
  fi

  if [ "$dist" = "debian" ] && [ "$version" = "11" ]; then
    apt -y install software-properties-common curl ca-certificates gnupg2 sudo lsb-release
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list
    apt update -y
  fi

  if [ "$dist" = "debian" ] && [ "$version" = "12" ]; then
    apt -y install software-properties-common curl ca-certificates gnupg2 sudo lsb-release apt-transport-https wget
    wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list
    apt update -y
  fi

  apt install -y mariadb-server tar unzip git redis-server nginx
  sed -i 's/character-set-collations = utf8mb4=uca1400_ai_ci/character-set-collations = utf8mb4=utf8mb4_general_ci/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
  systemctl restart mariadb

  apt -y install php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip}
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl
  curl -fsSL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/
  cp -n .env.example .env
  composer install --no-dev --optimize-autoloader --no-interaction
  php artisan key:generate --force

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
