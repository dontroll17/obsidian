#!/bin/bash
set -e

echo "=== Проверка обновлений и скачивание файлов через SteamCMD ==="
/home/steam/steamcmd/steamcmd.sh +force_install_dir /home/steam/hl2dm-server \
    +login anonymous \
    +app_update 232370 validate \
    +app_update 248890 validate \
    +app_update 220 validate \
    +app_update 380 validate \
    +app_update 420 validate \
    +quit

echo "=== Настройка путей монтирования контента (mount.cfg) ==="
cat << 'EOF' > /home/steam/hl2dm-server/obsidian/mount.cfg
"mount"
{
    "hl2"           "../hl2"
    "episodic"      "../episodic"
    "ep2"           "../ep2"
}
EOF

echo "=== Запуск выделенного сервера Obsidian Conflict ==="
cd /home/steam/hl2dm-server &&
chmod +x srcds_run srcds_linux &&
exec ./srcds_run -game obsidian +maxplayers 8 +map oc_harvest -port 27015 +rcon_password ${RCON_PASSWORD}