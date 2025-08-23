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
  run "cd /var/www/pterodactyl" "cd /var/www/pterodactyl"

  if [ "$SSL" = true ]; then
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

  # DB Host: MySQL user + Panel record (encrypted)
  create_database_host_user
  add_panel_database_host

  # ===== Defaults =====
  LOC_SHORT="dc1"
  LOC_LONG="Default Datacenter"

  NODE_NAME="${HOSTNAME:-auto}-node"
  NODE_DESC="Auto-created node"
  NODE_FQDN="$FQDN"
  NODE_PUBLIC="1"
  NODE_PROXY="0"
  NODE_MAINTENANCE="0"
  NODE_MAX_MEMORY="0"
  NODE_OVERALLOC_MEMORY="-1"
  NODE_MAX_DISK="0"
  NODE_OVERALLOC_DISK="-1"
  NODE_UPLOAD_SIZE="100"
  NODE_DAEMON_PORT="8080"
  NODE_SFTP_PORT="2022"
  NODE_BASE="/var/lib/pterodactyl/volumes"
  NODE_SCHEME="$([ "$SSL" = true ] && echo https || echo http)"

  run "Ensure Location '${LOC_SHORT}' exists" \
    "true"  # marker

  LOCATION_ID=$(mariadb -h 127.0.0.1 -u pterodactyl -p"$DBPASSWORD" panel -sN -e "SELECT id FROM locations WHERE short='${LOC_SHORT}' LIMIT 1;")
  if [ -z "$LOCATION_ID" ]; then
    run "Create Location ${LOC_SHORT}" \
      "php artisan p:location:make --short=\"$LOC_SHORT\" --long=\"$LOC_LONG\" || true"
    LOCATION_ID=$(mariadb -h 127.0.0.1 -u pterodactyl -p"$DBPASSWORD" panel -sN -e "SELECT id FROM locations WHERE short='${LOC_SHORT}' LIMIT 1;")
  fi
  [ -n "$LOCATION_ID" ] || { echo "Failed to create/find location '$LOC_SHORT'"; exit 1; }
  echo ">>> locationId=$LOCATION_ID"

  run "Ensure Node '${NODE_NAME}' exists" "true"

  NODE_ID=$(mariadb -h 127.0.0.1 -u pterodactyl -p"$DBPASSWORD" panel -sN -e "SELECT id FROM nodes WHERE fqdn='${NODE_FQDN}' OR name='${NODE_NAME}' ORDER BY id ASC LIMIT 1;")
  if [ -z "$NODE_ID" ]; then
    run "Create Node ${NODE_NAME}" \
      "php artisan p:node:make --name=\"$NODE_NAME\" --description=\"$NODE_DESC\" --locationId=\"$LOCATION_ID\" --fqdn=\"$NODE_FQDN\" --public=\"$NODE_PUBLIC\" --scheme=\"$NODE_SCHEME\" --proxy=\"$NODE_PROXY\" --maintenance=\"$NODE_MAINTENANCE\" --maxMemory=\"$NODE_MAX_MEMORY\" --overallocateMemory=\"$NODE_OVERALLOC_MEMORY\" --maxDisk=\"$NODE_MAX_DISK\" --overallocateDisk=\"$NODE_OVERALLOC_DISK\" --uploadSize=\"$NODE_UPLOAD_SIZE\" --daemonListeningPort=\"$NODE_DAEMON_PORT\" --daemonSFTPPort=\"$NODE_SFTP_PORT\" --daemonBase=\"$NODE_BASE\""

    NODE_ID=$(mariadb -h 127.0.0.1 -u pterodactyl -p"$DBPASSWORD" panel -sN -e "SELECT id FROM nodes WHERE fqdn='${NODE_FQDN}' OR name='${NODE_NAME}' ORDER BY id ASC LIMIT 1;")
  fi
  echo ">>> nodeId=${NODE_ID:-unknown}"

  run "Set ownership web files" \
    "chown -R www-data:www-data /var/www/pterodactyl/*"

  run "Install pteroq.service" \
    "curl -fsSL -o /etc/systemd/system/pteroq.service https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/pteroq.service"

  run "Add scheduler cron" \
    "(crontab -l 2>/dev/null; echo \"* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1\") | crontab -"

  run "Enable redis-server" \
    "systemctl enable --now redis-server"

  run "Enable pteroq.service" \
    "systemctl enable --now pteroq.service"

  if [ "$WINGS" = true ]; then
    run "Install Docker (get.docker.com)" \
      "curl -sSL https://get.docker.com/ | CHANNEL=stable bash"

    run "Enable docker" \
      "systemctl enable --now docker"

    run "Prepare /etc/pterodactyl" \
      "mkdir -p /etc/pterodactyl"

    run "Install curl tar unzip (wings deps)" \
      "apt-get -y install curl tar unzip"

    ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && WARCH="amd64" || WARCH="arm64"
    run "Download wings binary ($WARCH)" \
      "curl -fsSL -o /usr/local/bin/wings \"https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WARCH}\""

    run "Fetch wings.service" \
      "curl -fsSL -o /etc/systemd/system/wings.service \"https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/wings.service\""

    run "Make wings executable" \
      "chmod u+x /usr/local/bin/wings"

    echo ">>> Try generating /etc/pterodactyl/config.yml via Artisan…"
    if php artisan list | grep -q "p:node:configuration"; then
      run "Generate wings config via p:node:configuration" \
        "php artisan p:node:configuration --node=\"$NODE_ID\" --output=\"/etc/pterodactyl/config.yml\" || true"
    elif php artisan list | grep -q "p:wings:configuration"; then
      run "Generate wings config via p:wings:configuration" \
        "php artisan p:wings:configuration --node=\"$NODE_ID\" --output=\"/etc/pterodactyl/config.yml\" || true"
    else
      echo "(!) Artisan config command not found. Get config from Panel → Node → Configuration and save to /etc/pterodactyl/config.yml"
    fi

    run "Enable wings" \
      "systemctl enable --now wings || true"

    run "Restart wings" \
      "systemctl restart wings || true"
  fi

  if [ "$SSL" = "true" ]; then
    run "Remove default nginx site" \
      "rm -rf /etc/nginx/sites-enabled/default"

    run "Fetch nginx SSL vhost" \
      "curl -fsSL -o /etc/nginx/sites-enabled/pterodactyl.conf https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/pterodactyl-nginx-ssl.conf"

    run "Patch server_name in nginx conf" \
      "sed -i -e \"s@<domain>@${FQDN}@g\" /etc/nginx/sites-enabled/pterodactyl.conf"

    run "Stop nginx before certbot standalone" \
      "systemctl stop nginx || true"

    run "Issue certificate with certbot (standalone)" \
      "certbot certonly --standalone -d \"$FQDN\" --staple-ocsp --no-eff-email -m \"$EMAIL\" --agree-tos"

    run "Start nginx" \
      "systemctl start nginx"

    finish
  else
    run "Remove default nginx site" \
      "rm -rf /etc/nginx/sites-enabled/default"

    run "Fetch nginx HTTP vhost" \
      "curl -fsSL -o /etc/nginx/sites-enabled/pterodactyl.conf https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/pterodactyl-nginx.conf"

    run "Patch server_name in nginx conf" \
      "sed -i -e \"s@<domain>@${FQDN}@g\" /etc/nginx/sites-enabled/pterodactyl.conf"

    run "Restart nginx" \
      "systemctl restart nginx"

    finish
  fi
}

panel_install(){
  run "apt update" "apt update"
  run "Install certbot" "apt install -y certbot"

  if  [ "$dist" =  "ubuntu" ] && [ "$version" = "24.04" ]; then
    run "Install base packages (Ubuntu 24.04)" \
      "apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release"

    run "Add Ondrej PHP PPA" \
      "LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php"

    run "Add Redis repo key" \
      "curl -fsSL https://packages.redis.io/gpg | gpg --dearmor --batch --yes -o /usr/share/keyrings/redis-archive-keyring.gpg"

    run "Add Redis repo list" \
      "bash -c 'echo \"deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb \$(lsb_release -cs) main\" > /etc/apt/sources.list.d/redis.list'"

    # NOTE: شلّنا خطوة mariadb_repo_setup نهائياً
    run "apt update (after repos)" "apt update"

    run "Enable Ubuntu universe" \
      "add-apt-repository \"deb http://archive.ubuntu.com/ubuntu \$(lsb_release -sc) universe\" -y"
  fi

  if [ "$dist" = "debian" ] && [ "$version" = "11" ]; then
    run "Install base packages (Debian 11)" \
      "apt -y install software-properties-common curl ca-certificates gnupg2 sudo lsb-release"

    run "Add Sury PHP repo" \
      "bash -c 'echo \"deb https://packages.sury.org/php/ \$(lsb_release -sc) main\" > /etc/apt/sources.list.d/sury-php.list'"

    run "Add Sury GPG key" \
      "curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg"

    run "Add Redis repo key" \
      "curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg"

    run "Add Redis repo list" \
      "bash -c 'echo \"deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb \$(lsb_release -cs) main\" > /etc/apt/sources.list.d/redis.list'"

    run "apt update (after repos)" "apt update -y"

    # NOTE: شلّنا خطوة mariadb_repo_setup نهائياً
  fi

  if [ "$dist" = "debian" ] && [ "$version" = "12" ]; then
    run "Install base packages (Debian 12)" \
      "apt -y install software-properties-common curl ca-certificates gnupg2 sudo lsb-release apt-transport-https wget"

    run "Add Sury PHP GPG key" \
      "wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg"

    run "Add Sury PHP repo" \
      "bash -c 'echo \"deb https://packages.sury.org/php/ \$(lsb_release -sc) main\" > /etc/apt/sources.list.d/php.list'"

    run "Add Redis repo key" \
      "curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg"

    run "Add Redis repo list" \
      "bash -c 'echo \"deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb \$(lsb_release -cs) main\" > /etc/apt/sources.list.d/redis.list'"

    run "apt update (after repos)" "apt update -y"

    # NOTE: شلّنا خطوة mariadb_repo_setup نهائياً
  fi

  run "Install base services (MariaDB, tar, unzip, git, redis, nginx)" \
    "apt install -y mariadb-server tar unzip git redis-server nginx"

  run "Adjust MariaDB collation (compat tweak)" \
    "sed -i 's/character-set-collations = utf8mb4=uca1400_ai_ci/character-set-collations = utf8mb4=utf8mb4_general_ci/' /etc/mysql/mariadb.conf.d/50-server.cnf || true"

  run "Restart MariaDB" \
    "systemctl restart mariadb"

  run "Install PHP 8.3 + extensions" \
    "apt -y install php8.3 php8.3-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip}"

  run "Install composer" \
    "curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"

  run "Create /var/www/pterodactyl" \
    "mkdir -p /var/www/pterodactyl"

  run "cd /var/www/pterodactyl" \
    "cd /var/www/pterodactyl"

  run "Download Panel tar.gz (latest)" \
    "curl -fsSL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"

  run "Extract Panel" \
    "tar -xzf panel.tar.gz"

  run "Fix storage/cache perms" \
    "chmod -R 755 storage/* bootstrap/cache/"

  run "Copy .env.example to .env if missing" \
    "cp -n .env.example .env"

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
