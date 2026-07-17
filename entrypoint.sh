#!/bin/bash
set -euo pipefail

# === Константы и переменные ===
SERVER_DIR="/home/steam/hl-server"
STEAM_DIR="/home/steam"
MOUNT_FIX_FLAG="$SERVER_DIR/.mountfix_done"
SRCDS_RUN="$SERVER_DIR/srcds_run"

# === 1. Подготовка среды ===
mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"

# === 2. Установка системных зависимостей (с фиксом libtinfo5) ===
echo "=== Установка системных зависимостей (32-bit, gosu, p7zip, gnupg2, libc6-dev-i386) ==="
export DEBIAN_FRONTEND=noninteractive

# Сначала базовые зависимости + gnupg2 и 32-bit develop-пакеты
apt-get update -qq && apt-get install -y --no-install-recommends \
    lib32gcc-s1 lib32stdc++6 libstdc++6:i386 libtinfo6:i386 libcurl4:i386 \
    p7zip-full wget gosu gnupg2 build-essential libc6-dev-i386 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

echo "=== Проверка компиляции 32-битного кода ==="
echo 'int main() { return 0; }' > /tmp/test.c
if gcc -m32 /tmp/test.c -o /tmp/test32 2>/dev/null; then
    echo "✅ gcc -m32 работает"
else
    echo "❌ gcc -m32 не может создать исполняемый файл. Проверьте libc6-dev-i386."
    exit 1
fi

# Проверяем наличие libtinfo.so.5 и устанавливаем/собираем, если её нет
if ! ldconfig -p | grep -q 'libtinfo\.so\.5[^6]'; then
    echo "=== Установка libtinfo5:i386 (если недоступна — сборка из исходников) ==="
    
    # Попытка 1: установка через архивный репозиторий (jammy — Ubuntu 22.04)
    {
        echo "deb [arch=i386] http://archive.ubuntu.com/ubuntu/ jammy main universe" > /etc/apt/sources.list.d/ncurses5.list
        wget -qO - http://archive.ubuntu.com/ubuntu/project/ubuntu-archive-keyring.gpg 2>/dev/null | gpg --dearmor > /usr/share/keyrings/ubuntu-archive-keyring.gpg || true
        apt-get update -o Acquire::AllowDowngradesToInsecureRepositories=true 2>/dev/null || true
        apt-get install -y --allow-downgrades libtinfo5:i386 2>/dev/null && {
            echo "✅ libtinfo5:i386 установлен через архивный репозиторий"
        } || {
            echo "⚠️  Не удалось установить libtinfo5:i386 через apt. Сборка из исходников..."
        }
    } || {
        echo "⚠️  Архивный репозиторий недоступен. Сборка из исходников..."
    }

    # Попытка 2: сборка ncurses 5.9 из исходников (гарантированно работает)
    if ! ldconfig -p | grep -q 'libtinfo\.so\.5[^6]'; then
        echo "🔄 Сборка ncurses 5.9 (libtinfo.so.5)..."
        
        # Скачиваем исходники
        wget -q https://ftp.gnu.org/pub/gnu/ncurses/ncurses-5.9.tar.gz
        
        tar -xzf ncurses-5.9.tar.gz
        cd ncurses-5.9
        
        # Настройка и сборка 32-битной версии
        CC="gcc -m32" CXX="g++ -m32" \
        ./configure \
            --prefix=/usr \
            --libdir=/usr/lib/i386-linux-gnu \
            --with-pkg-config-libdir=/usr/lib/pkgconfig \
            --with-shared \
            --with-termlib \
            --with-hashed-db \
            --enable-widec \
            --disable-stripping
        
        make -j"$(nproc || echo 1)" && make install
        
        cd ..
        rm -rf ncurses-5.9.tar.gz ncurses-5.9
        
        # Обновляем кэш библиотек
        ldconfig
        
        # Проверка
        if ! ldconfig -p | grep -q 'libtinfo\.so\.5[^6]'; then
            echo "❌ Сборка libtinfo.so.5 не удалась."
            exit 1
        fi
        echo "✅ libtinfo.so.5 успешно собрана и установлена"
    fi
else
    echo "✅ libtinfo.so.5 уже найдена"
fi

# === 3. Первичная подготовка сервера (если отсутствует srcds_run) ===
if [ ! -x "$SRCDS_RUN" ]; then
    echo "=== Запуск SteamCMD для установки HL2:EP2 базы (app 232370) ==="
    
    /home/steam/steamcmd/steamcmd.sh \
        +force_install_dir "$SERVER_DIR" \
        +login anonymous \
        +app_update 232370 validate \
        +quit || {
        echo "❌ SteamCMD не удалось установить HL2:EP2. Проверьте подключение."
        exit 1
    }

    # Устанавливаем безопасные права на базу
    chown -R steam:steam "$SERVER_DIR"
    find "$SERVER_DIR" -type d -exec chmod 755 {} \;
    find "$SERVER_DIR" -type f -exec chmod 644 {} \;

    echo "=== HL2:EP2 установлено. Скачиваем и устанавливаем мод ObsidianConflict ==="
    
    # Создаём временную папку
    MOD_TEMP="$SERVER_DIR/mod_temp"
    mkdir -p "$MOD_TEMP"
    cd "$MOD_TEMP"

    # Скачиваем архив (если ещё не скачан)
    if [ ! -f "$SERVER_DIR/obsidian.7z" ]; then
        echo "⏳ Скачивание obsidian.7z (это может занять 10–30 минут)..."
        wget -q --show-progress -O "$SERVER_DIR/obsidian.7z" \
            "https://disk.yandex.ru/d/ZqpAD3Jcl60HjQ" || \
        wget -q -O "$SERVER_DIR/obsidian.7z" \
            "https://disk.yandex.ru/d/ZqpAD3Jcl60HjQ" || \
        {
            echo "❌ Не удалось скачать архив мода. Проверьте URL."
            exit 1
        }
    fi

    # Распаковка
    echo "🔍 Распаковка obsidian.7z..."
    7z x "$SERVER_DIR/obsidian.7z" -y -o"$MOD_TEMP" || {
        echo "❌ Ошибка распаковки мода. Проверьте целостность архива."
        exit 1
    }

    # Копируем только содержимое папки 'obsidian'
    if [ -d "$MOD_TEMP/obsidian" ]; then
        cp -rn "$MOD_TEMP/obsidian/"* "$SERVER_DIR/" 2>/dev/null || true
        # Копируем root-файлы мода (например, map .bsp)
        find "$MOD_TEMP" -maxdepth 1 -type f \( -name "*.bsp" -o -name "*.vbsp" \) -exec cp {} "$SERVER_DIR/" \; 2>/dev/null || true
    else
        echo "⚠️  В архиве нет папки 'obsidian'. Пропускаем."
    fi

    cd "$SERVER_DIR"
    rm -rf "$MOD_TEMP" "$SERVER_DIR/obsidian.7z"

    # Устанавливаем финальные права
    chown -R steam:steam "$SERVER_DIR"
    find "$SERVER_DIR" -type d -exec chmod 755 {} \;
    find "$SERVER_DIR" -type f -exec chmod 644 {} \;
fi

# === 4. Исправление steamclient.so (обязательно перед запуском) ===
echo "=== Настройка steamclient.so для предотвращения segfault ==="
mkdir -p "$STEAM_DIR/.steam/sdk32"
if [ -f "$STEAM_DIR/steamcmd/linux32/steamclient.so" ]; then
    ln -sf "$STEAM_DIR/steamcmd/linux32/steamclient.so" \
           "$STEAM_DIR/.steam/sdk32/steamclient.so"
    echo "✅ steamclient.so настроен"
else
    echo "⚠️  steamclient.so не найден. Проверьте путь: $STEAM_DIR/steamcmd/linux32/steamclient.so"
fi

# === 5. mountfix (одноразово) ===
if [ ! -f "$MOUNT_FIX_FLAG" ]; then
    echo "=== Выполнение mountfix (если присутствует) ==="
    
    # mountfix.sh
    if [ -f "$SERVER_DIR/mountfix.sh" ]; then
        echo "📂 Обнаружен mountfix.sh"
        chmod +x "$SERVER_DIR/mountfix.sh"
        if ! "$SERVER_DIR/mountfix.sh"; then
            echo "⚠️  mountfix.sh завершился с ошибкой, но продолжаем..."
        fi
    fi

    # mountfix.py
    if [ -f "$SERVER_DIR/mountfix.py" ]; then
        echo "🐍 Обнаружен mountfix.py"
        python3 "$SERVER_DIR/mountfix.py" || {
            echo "⚠️  mountfix.py завершился с ошибкой, но продолжаем..."
        }
    fi

    # Флаг завершения
    touch "$MOUNT_FIX_FLAG"
    rm -f "$SERVER_DIR/mountfix.sh" "$SERVER_DIR/mountfix.py"
    echo "✅ Mountfix завершён"
else
    echo "=== Mountfix уже выполнен ранее. Пропускаем. ==="
fi

# === 6. Установка обязательных файлов ===
echo "=== Создание обязательных конфигурационных файлов ==="

# steam_appid.txt
echo "232370" > "$SERVER_DIR/steam_appid.txt"

# mount.cfg — критичен для загрузки контента
mkdir -p "$SERVER_DIR/obsidian/cfg"
cat > "$SERVER_DIR/obsidian/cfg/mount.cfg" << 'EOF'
"mount"
{
    "hl2"           "../hl2"
    "episodic"      "../episodic"
    "ep2"           "../ep2"
}
EOF

# === 7. Diagnostics: check-segfault (встроенная проверка) ===
echo "=== 🔍 Диагностика перед запуском (check-segfault) ==="

DIAG_ERRORS=0
DIAG_WARNINGS=0

# Функция для вывода результатов
check_result() {
    local status="$1"
    local message="$2"
    if [ "$status" == "OK" ]; then
        echo "✅ $message"
    elif [ "$status" == "WARN" ]; then
        echo "⚠️  $message"
        DIAG_WARNINGS=$((DIAG_WARNINGS + 1))
    else
        echo "❌ $message"
        DIAG_ERRORS=$((DIAG_ERRORS + 1))
    fi
}

# 1. libtinfo.so.5
echo -n "1. libtinfo.so.5: "
if ! ldconfig -p | grep -q 'libtinfo\.so\.5[^6]'; then
    echo "❌ Не найдена"
    DIAG_ERRORS=$((DIAG_ERRORS + 1))
else
    echo "✅ Найдена: $(readlink -f /usr/lib/i386-linux-gnu/libtinfo.so.5)"
fi

# 2. steamclient.so
echo -n "2. steamclient.so: "
if [ -f "$STEAM_DIR/.steam/sdk32/steamclient.so" ]; then
    echo "✅ Найден: $(readlink -f "$STEAM_DIR/.steam/sdk32/steamclient.so")"
else
    echo "⚠️  Отсутствует. Создаём..."
    mkdir -p "$STEAM_DIR/.steam/sdk32"
    if [ -f "$STEAM_DIR/steamcmd/linux32/steamclient.so" ]; then
        ln -sf "$STEAM_DIR/steamcmd/linux32/steamclient.so" \
               "$STEAM_DIR/.steam/sdk32/steamclient.so" || {
            echo "❌ Не удалось создать симлинк"
            DIAG_ERRORS=$((DIAG_ERRORS + 1))
        }
        echo "✅ Создано: $STEAM_DIR/.steam/sdk32/steamclient.so"
    else
        echo "❌ Источник не найден ($STEAM_DIR/steamcmd/linux32/steamclient.so)"
        DIAG_ERRORS=$((DIAG_ERRORS + 1))
    fi
fi

# 3. 32-битные зависимости client.so (если файл существует)
if [ -f "$SERVER_DIR/obsidian/bin/client.so" ]; then
    echo -n "3. client.so: "
    if ldd "$SERVER_DIR/obsidian/bin/client.so" 2>&1 | grep -q "not found"; then
        echo "⚠️  Есть зависимости с ошибками:"
        ldd "$SERVER_DIR/obsidian/bin/client.so" 2>&1 | grep "not found" | while read line; do echo "   ❌ $line"; done
        DIAG_WARNINGS=$((DIAG_WARNINGS + 1))
    else
        echo "✅ Зависимости OK"
    fi
else
    echo "3. client.so: ⚠️  Не найден. Сервер не запустится."
    DIAG_ERRORS=$((DIAG_ERRORS + 1))
fi

# 4. steam_appid.txt
echo -n "4. steam_appid.txt: "
if grep -q "232370" "$SERVER_DIR/steam_appid.txt" 2>/dev/null; then
    echo "✅ Корректный appid (232370)"
else
    echo "❌ Ошибка или отсутствует"
    DIAG_ERRORS=$((DIAG_ERRORS + 1))
fi

# 5. mount.cfg
echo -n "5. mount.cfg: "
if [ -f "$SERVER_DIR/obsidian/cfg/mount.cfg" ] && grep -q "hl2" "$SERVER_DIR/obsidian/cfg/mount.cfg"; then
    echo "✅ Найден и содержит 'hl2'"
else
    echo "⚠️  Отсутствует или битый"
    DIAG_WARNINGS=$((DIAG_WARNINGS + 1))
fi

# 6. srcds_run
echo -n "6. srcds_run: "
if [ -x "$SRCDS_RUN" ]; then
    echo "✅ Исполняемый файл найден"
else
    echo "❌ Не найден или не исполняемый"
    DIAG_ERRORS=$((DIAG_ERRORS + 1))
fi

# === Итог проверки ===
echo ""
echo "=== 📊 Итог диагностики ==="
if [ "$DIAG_ERRORS" -gt 0 ]; then
    echo "❌ Обнаружено $DIAG_ERRORS критических ошибок. Сервер не запустится."
    echo "💡 Подробности выше. Исправьте ошибки перед запуском."
    exit 1
else
    echo "✅ Критических ошибок не обнаружено ($DIAG_ERRORS ошибок, $DIAG_WARNINGS предупреждений)"
fi


# === 8. Запуск сервера ===
echo "🚀 Запуск сервера Obsidian Conflict..."
echo "   Порт: 27015"
echo "   Режим: -debug, maxplayers 8, map oc_harvest"

# Переключение на steam (с gosu, если доступен)
if command -v gosu >/dev/null 2>&1; then
    # Создаём пользователя, если его нет (на всякий случай)
    if ! id -u steam >/dev/null 2>&1; then
        useradd -m -s /bin/bash steam 2>/dev/null || true
    fi
    exec gosu steam "$SRCDS_RUN" \
        -game obsidian \
        -console \
        -nojoy \
        -novid \
        -debug \
        +maxplayers 8 \
        +map oc_harvest \
        -port 27015 \
        +rcon_password "${RCON_PASSWORD}" \
        +sv_lan 0 \
        +game_type 0 \
        +game_mode 0 \
        +sv_pausable 0 \
        +mp_timelimit 0 \
        +sv_tags "Obsidian,MP,Source"
else
    echo "⚠️  gosu не найден — используем su (менее безопасно)"
    exec su -s /bin/bash -c "exec $0 $*" steam 2>/dev/null || \
    exec su -s /bin/bash steam -c "exec $SRCDS_RUN $*" 2>/dev/null || \
    {
        echo "❌ gosu и su недоступны. Установите пакет gosu."
        exit 1
    }
fi