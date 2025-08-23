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

finish(){
  clear || true
  echo ""
  echo "[Vndel] [!] Panel installed."
  echo ""
}

require_arg(){ if [ -z "${!1:-}" ]; then echo "Missing arg: $1"; exit 1; fi; }

create_database_host_user() {
  # DB host user/password:
  # - user      : pterodactyl
  # - password  : SAME as panel DB user password (DBPASSWORD)
  # - host addr : '%' (يسهل الاتصال حتى لو غيرت الاستضافة) — واللوحة هتتصل على FQDN.
  echo ">>> Ensuring MySQL user for Database Host… (pterodactyl@%)"
  mariadb -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'%' IDENTIFIED BY '${DBPASSWORD}';"
  mariadb -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'pterodactyl'@'%' WITH GRANT OPTION;"
  mariadb -u root -e "FLUSH PRIVILEGES;"

  echo ">>> Database Host info (add in Panel → Admin → Databases → Hosts):"
  echo "    Name: game-dbhost"
  echo "    Host: ${FQDN}"
  echo "    Port: 3306"
  echo "    Username: pterodactyl"
  echo "    Password: ${DBPASSWORD}"
}

add_panel_database_host() {
  # نستخدم نفس قيمك:
  # - Host = FQDN
  # - Username = pterodactyl
  # - Password = نفس DBPASSWORD اللي اتولد للبانل
  # - Port = 3306
  # - Name = game-dbhost
  # - max_databases = 0 (غير محدود)

  echo ">>> Adding Database Host into the Panel (via Laravel, encrypted password)…"

  ( cd /var/www/pterodactyl && \
    FQDN="$FQDN" DBPASSWORD="$DBPASSWORD" php -r '
      require "vendor/autoload.php";
      $app = require "bootstrap/app.php";
      $kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
      $kernel->bootstrap();

      // نستخدم موديل اللوحة لضمان نفس التشفير
      $name     = "game-dbhost";
      $host     = getenv("FQDN") ?: "127.0.0.1";
      $port     = 3306;
      $username = "pterodactyl";
      $password = getenv("DBPASSWORD");   // Laravel سيشفّرها تلقائياً حسب إعدادات المشروع

      // متغيرات إضافية شائعة في بعض الإصدارات — لو غير موجودة في سكيمتك سيتجاهلها Eloquent:
      $attrs = [
        "name"           => $name,
        "host"           => $host,
        "port"           => $port,
        "username"       => $username,
        "password"       => $password,
        "max_databases"  => 0,
        // "node_id"      => null,   // فعّلها لو تبغى تربطه بنود معيّن
        // "ssl"          => 0,      // في حال وجود عمود ssl في نسختك
      ];

      // نحاول إحضار الموديل مع توافق الأسماء عبر الإصدارات
      $model = null;
      if (class_exists("Pterodactyl\\Models\\DatabaseHost")) {
        $model = "Pterodactyl\\Models\\DatabaseHost";
      } elseif (class_exists("Pterodactyl\\Models\\Database\\Host")) {
        $model = "Pterodactyl\\Models\\Database\\Host";
      } else {
        fwrite(STDERR, "DatabaseHost model not found.\\n");
        exit(1);
      }

      // idempotent: لو موجود بنفس (host,port,username) نحدّثه، وإلا ننشئه
      $model::updateOrCreate(
        ["host" => $host, "port" => $port, "username" => $username],
        $attrs
      );

      echo "OK\\n";
    ' )
}


panel_conf(){
  cd /var/www/pterodactyl

  # URL حسب SSL
  if [ "$SSL" = true ]; then
    appurl="https://${FQDN}"
  else
    appurl="http://${FQDN}"
  fi

  # أسماء الأدمن تلقائي
  FIRSTNAME="Vndel"
  LASTNAME="Creator"

  # باسورد مستخدم قاعدة بيانات اللوحة (وسنستخدمه أيضًا لِـ DB Host user)
  DBPASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | fold -w 16 | head -n 1)

  # إنشاء DB + user للوحة
  mariadb -u root -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DBPASSWORD}';"
  mariadb -u root -e "CREATE DATABASE IF NOT EXISTS panel;"
  mariadb -u root -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
  mariadb -u root -e "FLUSH PRIVILEGES;"

  # تهيئة بيئة اللوحة
  php artisan p:environment:setup \
    --author="$EMAIL" --url="$appurl" --timezone="CET" --telemetry=false \
    --cache="redis" --session="redis" --queue="redis" \
    --redis-host="localhost" --redis-pass="null" --redis-port="6379" \
    --settings-ui=true

  php artisan p:environment:database \
    --host="127.0.0.1" --port="3306" --database="panel" \
    --username="pterodactyl" --password="$DBPASSWORD"

  php artisan migrate --seed --force

  # إنشاء الأدمن
  php artisan p:user:make \
    --email="$EMAIL" --username="$USERNAME" \
    --name-first="$FIRSTNAME" --name-last="$LASTNAME" \
    --password="$PASSWORD" --admin=1

  # إنشاء/تجهيز Database Host user (نفس باسورد DBPASSWORD)
  create_database_host_user
  
  # إنشاء/تجهيز Database Panel user (نفس باسورد DBPASSWORD)
  add_panel_database_host

  # ===== Defaults للـ Location/Node (بدون exports) =====
  LOC_SHORT="dc1"
  LOC_LONG="Default Datacenter"

  NODE_NAME="${HOSTNAME:-auto}-node"
  NODE_DESC="Auto-created node"
  NODE_FQDN="$FQDN"                       # نفس دومين اللوحة افتراضيًا
  NODE_PUBLIC="1"
  NODE_PROXY="0"
  NODE_MAINTENANCE="0"
  NODE_MAX_MEMORY="0"                     # MB (0=غير محدود)
  NODE_OVERALLOC_MEMORY="-1"              # -1 = أقصى أوفر
  NODE_MAX_DISK="0"                       # MB (0=غير محدود)
  NODE_OVERALLOC_DISK="-1"
  NODE_UPLOAD_SIZE="100"                  # MB
  NODE_DAEMON_PORT="8080"
  NODE_SFTP_PORT="2022"
  NODE_BASE="/var/lib/pterodactyl/volumes"
  NODE_SCHEME="$([ "$SSL" = true ] && echo https || echo http)"

  # إنشاء Location ثم Node (idempotent)
  echo ">>> Ensuring Location '${LOC_SHORT}'…"
  LOCATION_ID=$(mariadb -h 127.0.0.1 -u pterodactyl -p"$DBPASSWORD" panel -sN \
    -e "SELECT id FROM locations WHERE short='${LOC_SHORT}' LIMIT 1;")
  if [ -z "$LOCATION_ID" ]; then
    php artisan p:location:make --short="$LOC_SHORT" --long="$LOC_LONG" || true
    LOCATION_ID=$(mariadb -h 127.0.0.1 -u pterodactyl -p"$DBPASSWORD" panel -sN \
      -e "SELECT id FROM locations WHERE short='${LOC_SHORT}' LIMIT 1;")
  fi
  [ -n "$LOCATION_ID" ] || { echo "Failed to create/find location '$LOC_SHORT'"; exit 1; }
  echo ">>> locationId=$LOCATION_ID"

  echo ">>> Ensuring Node '${NODE_NAME}'…"
  NODE_ID=$(mariadb -h 127.0.0.1 -u pterodactyl -p"$DBPASSWORD" panel -sN \
    -e "SELECT id FROM nodes WHERE fqdn='${NODE_FQDN}' OR name='${NODE_NAME}' ORDER BY id ASC LIMIT 1;")
  if [ -z "$NODE_ID" ]; then
    php artisan p:node:make \
      --name="$NODE_NAME" \
      --description="$NODE_DESC" \
      --locationId="$LOCATION_ID" \
      --fqdn="$NODE_FQDN" \
      --public="$NODE_PUBLIC" \
      --scheme="$NODE_SCHEME" \
      --proxy="$NODE_PROXY" \
      --maintenance="$NODE_MAINTENANCE" \
      --maxMemory="$NODE_MAX_MEMORY" \
      --overallocateMemory="$NODE_OVERALLOC_MEMORY" \
      --maxDisk="$NODE_MAX_DISK" \
      --overallocateDisk="$NODE_OVERALLOC_DISK" \
      --uploadSize="$NODE_UPLOAD_SIZE" \
      --daemonListeningPort="$NODE_DAEMON_PORT" \
      --daemonSFTPPort="$NODE_SFTP_PORT" \
      --daemonBase="$NODE_BASE"

    NODE_ID=$(mariadb -h 127.0.0.1 -u pterodactyl -p"$DBPASSWORD" panel -sN \
      -e "SELECT id FROM nodes WHERE fqdn='${NODE_FQDN}' OR name='${NODE_NAME}' ORDER BY id ASC LIMIT 1;")
  fi
  echo ">>> nodeId=${NODE_ID:-unknown}"

  chown -R www-data:www-data /var/www/pterodactyl/*
  curl -fsSL -o /etc/systemd/system/pteroq.service \
    https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/pteroq.service

  (crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

  systemctl enable --now redis-server
  systemctl enable --now pteroq.service

  # Wings (اختياري)
  if [ "$WINGS" = true ]; then
    echo ">>> Installing Wings…"
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker
    mkdir -p /etc/pterodactyl
    apt-get -y install curl tar unzip
    ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && WARCH="amd64" || WARCH="arm64"
    curl -fsSL -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WARCH}"
    curl -fsSL -o /etc/systemd/system/wings.service "https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/wings.service"
    chmod u+x /usr/local/bin/wings

    # نحاول توليد config.yml عبر Artisan (بدون token / node id من المستخدم)
    echo ">>> Generating /etc/pterodactyl/config.yml via Artisan (if available)…"
    if php artisan list | grep -q "p:node:configuration"; then
      php artisan p:node:configuration --node="$NODE_ID" --output="/etc/pterodactyl/config.yml" || true
    elif php artisan list | grep -q "p:wings:configuration"; then
      php artisan p:wings:configuration --node="$NODE_ID" --output="/etc/pterodactyl/config.yml" || true
    else
      echo "(!) Artisan config command not found. Get config from Panel → Node → Configuration and save to /etc/pterodactyl/config.yml"
    fi

    systemctl enable --now wings || true
    systemctl restart wings || true
  fi

  # Nginx & SSL
  if [ "$SSL" = "true" ]; then
    rm -rf /etc/nginx/sites-enabled/default
    curl -fsSL -o /etc/nginx/sites-enabled/pterodactyl.conf \
      https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/pterodactyl-nginx-ssl.conf
    sed -i -e "s@<domain>@${FQDN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
    systemctl stop nginx || true
    certbot certonly --standalone -d "$FQDN" --staple-ocsp --no-eff-email -m "$EMAIL" --agree-tos
    systemctl start nginx
    finish
  else
    rm -rf /etc/nginx/sites-enabled/default
    curl -fsSL -o /etc/nginx/sites-enabled/pterodactyl.conf \
      https://raw.githubusercontent.com/guldkage/Pterodactyl-Installer/main/configs/pterodactyl-nginx.conf
    sed -i -e "s@<domain>@${FQDN}@g" /etc/nginx/sites-enabled/pterodactyl.conf
    systemctl restart nginx
    finish
  fi
}

panel_install(){
  echo ">>> Updating APT and installing prerequisites…"
  apt update
  apt install -y certbot

  if  [ "$dist" =  "ubuntu" ] && [ "$version" = "24.04" ]; then
    apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor --batch --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash
    apt update
    add-apt-repository "deb http://archive.ubuntu.com/ubuntu $(lsb_release -sc) universe" -y
  fi

  if [ "$dist" = "debian" ] && [ "$version" = "11" ]; then
    apt -y install software-properties-common curl ca-certificates gnupg2 sudo lsb-release
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
    curl -fsSL  https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-keyring.gpg
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list
    apt update -y
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash
  fi

  if [ "$dist" = "debian" ] && [ "$version" = "12" ]; then
    apt -y install software-properties-common curl ca-certificates gnupg2 sudo lsb-release apt-transport-https wget
    wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list
    apt update -y
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash
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
