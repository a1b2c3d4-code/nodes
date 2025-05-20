#!/bin/bash

set -o errexit
trap 'echo "⚠️  Ошибка выполнения. Возврат в главное меню."' ERR

# Каталог скрипта и файл с данными
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRED_FILE="$SCRIPT_DIR/db_credentials.env"

DB_PORT=5432
DB_HOST="localhost"
SETTINGS_FILE="teneo_farm/settings.yaml"

# Определяем последнюю версию PostgreSQL
PG_VERSION=$(ls /etc/postgresql 2>/dev/null | sort -nr | head -n 1)
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

function install_postgresql() {
  echo "[1] Установка PostgreSQL..."
  apt update && apt install -y postgresql > /dev/null
  echo "✅ PostgreSQL установлен."

  # Определение пути к конфигу
  PG_VERSION=$(ls /etc/postgresql | sort -nr | head -n 1)
  POSTGRES_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"

  # Настройка конфигурации
  sed -i "s|^#listen_addresses = 'localhost'|listen_addresses = '*'|g" "$POSTGRES_CONF"

  systemctl restart postgresql
}

function create_teneo_database() {
  echo "[2] Создание базы данных и пользователя для Teneo..."

  DB_NAME="teneo_$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
  DB_USER="user_$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
  DB_PASSWORD="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"

  sudo -u postgres psql <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;

\c $DB_NAME

GRANT USAGE ON SCHEMA public TO $DB_USER;
GRANT CREATE ON SCHEMA public TO $DB_USER;
ALTER SCHEMA public OWNER TO $DB_USER;
EOF

  cat > "$CRED_FILE" <<EOL
host=$DB_HOST
port=$DB_PORT
name=$DB_NAME
user=$DB_USER
password=$DB_PASSWORD
EOL

  echo "✅ База данных '${DB_NAME}' и пользователь '${DB_USER}' созданы с необходимыми правами."
}

function show_connection_data() {
  echo "[3] Данные для подключения к базе:"
  if [[ -f "$CRED_FILE" ]]; then
    echo
    echo "database:"
    while IFS='=' read -r key value; do
      printf "  %-8s: %s\n" "$key" "$value"
    done < "$CRED_FILE"
    echo
  else
    echo "⚠️  Данные подключения не найдены. Сначала создайте базу (пункт 2)."
    echo
  fi
}

function install_python() {
  echo "[4] Установка Python 3.11..."
  apt update
  apt install -y software-properties-common
  add-apt-repository -y ppa:deadsnakes/ppa
  apt update
  apt install -y python3.11 python3.11-venv python3.11-dev
  echo "✅ Python 3.11 установлен."
}

function download_teneo_script() {
  echo "[5] Загрузка скрипта Teneo..."
  git clone https://github.com/gaanss/teneo_farm.git
  echo "✅ Скрипт Teneo загружен в папку ./teneo_farm"
}

function update_teneo_script() {
  echo "[6] Обновление скрипта Teneo..."

  if [ ! -d "$SCRIPT_DIR/teneo_farm/.git" ]; then
    echo "❌ Каталог ./teneo_farm не является git-репозиторием."
    return 1
  fi

  cd "$SCRIPT_DIR/teneo_farm" || {
    echo "❌ Не удалось перейти в каталог teneo_farm."
    return 1
  }

  git pull origin main || echo "⚠️  Не удалось обновить репозиторий. Проверьте соединение или конфликты."
  echo "✅ Скрипт Teneo обновлён."

  cd "$SCRIPT_DIR"
}

function connect_database_to_script() {
  echo "[7] Подключение базы данных к скрипту..."

  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "❌ Файл $SETTINGS_FILE не найден."
    return 1
  fi

  if [ ! -f "$CRED_FILE" ]; then
    echo "❌ Файл с данными подключения не найден: $CRED_FILE"
    return 1
  fi

  source <(sed 's/^/export /' "$CRED_FILE")

  awk -v host="$host" -v port="$port" -v name="$name" -v user="$user" -v password="$password" '
    BEGIN { in_block = 0 }
    /^database:/ { print; in_block = 1; next }
    /^[^[:space:]]/ { in_block = 0 }

    in_block == 1 {
      if ($1 == "host:")     { print "  host: " host; next }
      if ($1 == "port:")     { print "  port: " port; next }
      if ($1 == "name:")     { print "  name: " name; next }
      if ($1 == "user:")     { print "  user: " user; next }
      if ($1 == "password:") { print "  password: " password; next }
    }

    { print }
  ' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"

  echo "✅ Раздел database в settings.yaml обновлён."
}

function run_teneo_script() {
    echo "[8] Запуск Teneo в screen-сессии..."

    local CURRENT_DIR
    CURRENT_DIR="$(pwd)"
    local SCREEN_NAME="teneo_farm"
    local TENEO_PATH="$SCRIPT_DIR/teneo_farm/teneo_farm"

    # Проверка и установка screen при необходимости
    if ! command -v screen &> /dev/null; then
        echo "🔧 Утилита screen не найдена. Установка..."
        apt update && apt install -y screen
        echo "✅ screen установлен."
    fi

    # Проверка наличия исполняемого файла
    if [ ! -f "$TENEO_PATH" ]; then
        echo "❌ Файл $TENEO_PATH не найден."
        return 0
    fi

    cd "$SCRIPT_DIR/teneo_farm" || {
        echo "❌ Каталог teneo_farm не найден."
        cd "$CURRENT_DIR"
        return 0
    }

    chmod +x ./teneo_farm

    # Если сессия уже есть — переподключаемся, иначе создаём новую
    if screen -list | grep -q "\.${SCREEN_NAME}[[:space:]]"; then
        echo "⚠️  screen-сессия '$SCREEN_NAME' уже запущена. Подключение..."
        screen -r "$SCREEN_NAME"
    else
        screen -S "$SCREEN_NAME" ./teneo_farm
    fi

    cd "$CURRENT_DIR"
}


while true; do
  echo ""
  echo "Выберите действие:"
  echo "1) Установить PostgreSQL"
  echo "2) Создать базу для Teneo"
  echo "3) Показать данные для подключения к базе"
  echo "4) Установить Python 3.11"
  echo "5) Скачать скрипт Teneo"
  echo "6) Обновить скрипт Teneo"
  echo "7) Подключить базу к скрипту Teneo"
  echo "8) Запустить скрипт Teneo"
  echo "9) Выйти из скрипта"
  read -p "Введите номер пункта: " choice

  case $choice in
    1) install_postgresql;;
    2) create_teneo_database;;
    3) show_connection_data;;
    4) install_python;;
    5) download_teneo_script;;
    6) update_teneo_script;;
    7) connect_database_to_script;;
    8) run_teneo_script;;
    9) echo "Выход..."; exit 0;;
    *) echo "❌ Неверный ввод. Попробуйте снова.";;
  esac
done
