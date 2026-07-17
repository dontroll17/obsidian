#!/bin/bash
set -e

SERVER_DIR="/home/steam/hl2dm-server"
mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

# URL вашего архива
SERVER_7Z_URL="https://ocdownload.raidensnakesden.net/obsidianserverhotfixspecial.7z"

# === 1. Автоматическое скачивание и распаковка ===
# Проверяем, пуста ли папка (нет ли там главного исполняемого файла srcds_run)
if [ ! -f "./srcds_run" ]; then
    echo "=== Папка сервера пуста. Начинаю подготовку... ==="
    
    /usr/games/steamcmd +force_install_dir "$SERVER_DIR" \
        +login anonymous \
        +app_update 244630 validate \
        +quit

    # Обновляем пакеты и устанавливаем p7zip для работы с .7z, а также wget
    apt-get update && apt-get install -y p7zip-full wget python3
    
    echo "=== Скачивание архива .7z (это может занять время)... ==="
    wget -O server.7z "$SERVER_7Z_URL"
    
    echo "=== Распаковка архива .7z... ==="
    # Флаг -y автоматически соглашается на перезапись файлов, если они есть
    7z x server.7z -y
    
    # Удаляем архив после успешной распаковки для экономии места
    rm server.7z
    echo "=== Скачивание и распаковка завершены успешно! ==="
fi

# === 2. Автоматический запуск mountfix ===
# Проверяем наличие скрипта исправления путей в распакованном архиве
if [ -f "./mountfix.sh" ]; then
    echo "=== Обнаружен mountfix.sh, запускаю исправление путей... ==="
    chmod +x ./mountfix.sh
    ./mountfix.sh
    mv ./mountfix.sh ./mountfix.sh.done
    echo "=== Mountfix (.sh) успешно выполнен! ==="
elif [ -f "./mountfix.py" ]; then
    echo "=== Обнаружен mountfix.py, запускаю через Python... ==="
    # На всякий случай ставим python3, если его не было
    apt-get update && apt-get install -y python3
    python3 ./mountfix.py
    mv ./mountfix.py ./mountfix.py.done
    echo "=== Mountfix (.py) успешно выполнен! ==="
else
    echo "=== Mountfix не найден или уже был выполнен ранее. Пропускаем. ==="
fi

# === 3. Настройка путей монтирования контента (mount.cfg) ===
echo "=== Настройка путей монтирования контента (mount.cfg) ==="
mkdir -p obsidian
cat << 'EOF' > obsidian/mount.cfg
"mount"
{
    "hl2"           "../hl2"
    "episodic"      "../episodic"
    "ep2"           "../ep2"
}
EOF

# === 4. Запуск выделенного сервера Obsidian Conflict ===
echo "=== Запуск выделенного сервера Obsidian Conflict ==="
chmod +x srcds_run srcds_linux

# Переключаемся на безопасного пользователя steam для запуска самого процесса сервера,
# так как Valve запрещает запускать движок Source от root.
exec su steam -c "./srcds_run -game obsidian +maxplayers 8 +map oc_harvest -port 27015 +rcon_password \"${RCON_PASSWORD}\""
