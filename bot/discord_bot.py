
import asyncio
import aiorcon
import time
import numpy as np

import os
import discord
from discord import app_commands
from discord.ext import commands

# Считываем настройки из переменных окружения, которые прокинул Docker
SERVER_IP = os.getenv("SERVER_IP")
RCON_PORT = int(os.getenv("RCON_PORT", 27015))
RCON_PASSWORD = os.getenv("RCON_PASSWORD")
DISCORD_TOKEN = os.getenv("DISCORD_TOKEN")
SERVER_REAL_IP = os.getenv("SERVER_REAL_IP", SERVER_IP)
NOTIFY_CHANNEL_ID = os.getenv("DISCORD_CHANNEL_ID")

class OCControlBot(commands.Bot):
    def __init__(self):
        intents = discord.Intents.default()
        # Для слэш-команд текстовый интент не обязателен, но оставим для гибкости
        intents.message_content = True 
        super().__init__(command_prefix="!", intents=intents)

    async def setup_hook(self):
        # Синхронизирует слэш-команды с серверами Discord при запуске
        await self.tree.sync()
        print("Слэш-команды успешно синхронизированы!")

bot = OCControlBot()


async def execute_rcon(command: str) -> str:
    """Полностью асинхронное ядро для отправки любых команд на игровой сервер"""
    try:
        # Создаем неблокирующее RCON-подключение
        # Передаем IP, порт, пароль и выставляем таймаут в 3 секунды, чтобы бот не ждал вечно
        current_loop = asyncio.get_running_loop()

        rcon = await aiorcon.RCON.create(
            host=SERVER_IP, 
            port=RCON_PORT, 
            password=RCON_PASSWORD,
            timeout=3.0,
            loop=current_loop
        )
        
        # Отправляем команду и ждем ответ от сервера игры
        response = await rcon.send(command)
        
        # Закрываем соединение
        rcon.close()
        
        return response if response else "✅ Команда выполнена сервером успешно."
    except asyncio.TimeoutError:
        return "❌ Ошибка: Превышено время ожидания ответа от игрового сервера (Timeout)."
    except Exception as e:
        return f"❌ Ошибка связи с сервером игры: {e}"


@bot.event
async def on_ready():
    print(f"Робот {bot.user.name} вошел в сеть и готов к глобальным ивентам!")
    if NOTIFY_CHANNEL_ID:
        try:
            channel = bot.get_channel(int(NOTIFY_CHANNEL_ID))
            if channel:
                # Создаем красивую эмбед-плашку
                embed = discord.Embed(
                    title="🚜 Ферма OC_HARVEST успешно запущена!", 
                    description="Игровой сервер развернут из Git и готов принимать фермеров-рейверов.", 
                    color=discord.Color.green()
                )
                embed.add_field(name="🌐 IP адрес сервера:", value=f"`{SERVER_REAL_IP}:27015`", inline=False)
                embed.add_field(
                    name="⌨️ Команда для консоли игры (~):", 
                    value=f"```text\nconnect {SERVER_REAL_IP}:27015\n```", 
                    inline=False
                )
                embed.add_field(name="📻 FastDL статус:", value="✅ Активен (карты качаются быстро)", inline=True)
                embed.set_footer(text="Введите /play [ссылка_vk], чтобы запустить музыку и физику баса")
                
                await channel.send(embed=embed)
                print("Уведомление об успешном запуске отправлено в Дискорд!")
        except Exception as e:
            print(f"Не удалось отправить уведомление в канал: {e}")

    await bot.change_presence(activity=discord.Game(name="Obsidian Conflict"))

# =================================================================
# МОДУЛЬ 1: КОНСТРУКТОР ДИНАМИЧЕСКИХ СОБЫТИЙ (ИВЕНТОВ)
# =================================================================

@bot.tree.command(name="event", description="Запустить глобальный кастомный ивент на сервере")
@app_commands.describe(
    type="Выберите тип ивента",
    intensity="Насколько жестким будет событие?"
)
@app_commands.choices(type=[
    app_commands.Choice(name="💀 Нашествие зомби (Тьма)", value="zombie_night"),
    app_commands.Choice(name="📦 Аирдроп припасов", value="airdrop"),
    app_commands.Choice(name="⚡ Режим Бога (Для тестов)", value="sandbox"),
    app_commands.Choice(name="☀️ Сбросить все настройки", value="reset")
])
async def event(interaction: discord.Interaction, type: str, intensity: int = 1):
    """Позволяет запускать заготовленные сценарии с разной степенью сложности"""
    await interaction.response.defer() # Задерживаем ответ, пока RCON думает
    
    if type == "zombie_night":
        hp = 100 * intensity
        cmd = f"oc_sv_flashlight_recharge_rate 0; sk_zombie_health {hp}; oc_spawn_npc npc_zombie"
        await execute_rcon(cmd)
        await interaction.followup.send(
            f"💀 **ГЛОБАЛЬНЫЙ ИВЕНТ:** Наступила тьма {intensity}-го уровня! Здоровье зомби: {hp} HP!"
        )

    elif type == "airdrop":
        # Спавним столько ящиков, сколько указано в интенсивности
        cmd = ""
        for _ in range(intensity):
            cmd += "ent_create item_ammo_smg1; ent_create item_healthkit; "
        await execute_rcon(cmd)
        await interaction.followup.send(f"📦 **АИРДРОП:** На ферму сброшено припасов х{intensity}!")

    elif type == "sandbox":
        cmd = "sv_cheats 1; oc_sv_flashlight_recharge_rate 999; oc_sv_lives -1"
        await execute_rcon(cmd)
        await interaction.followup.send("⚡ **РЕЖИМ ПЕСОЧНИЦЫ:** Читы включены, фонарики бесконечные.")

    elif type == "reset":
        cmd = "sv_cheats 0; oc_sv_flashlight_recharge_rate 100; sk_zombie_health 50"
        await execute_rcon(cmd)
        await interaction.followup.send("☀️ **СБРОС:** Все настройки игрового процесса возвращены по умолчанию.")

# =================================================================
# МОДУЛЬ 2: СПАВНЕР ОБЪЕКТОВ И NPC ПО ВЫБОРУ
# =================================================================

@bot.tree.command(name="spawn", description="Заспавнить конкретного монстра или предмет на карте")
@app_commands.describe(
    entity="Что именно спавним?",
    amount="Количество (от 1 до 10)"
)
@app_commands.choices(entity=[
    app_commands.Choice(name="Обычный Зомби", value="npc_zombie"),
    app_commands.Choice(name="Быстрый Зомби", value="npc_fastzombie"),
    app_commands.Choice(name="Мутант Муравьиный лев", value="npc_antlion"),
    app_commands.Choice(name="Аптечка", value="item_healthkit"),
    app_commands.Choice(name="Дробовик", value="weapon_shotgun")
])
async def spawn(interaction: discord.Interaction, entity: str, amount: int = 1):
    """Гибкий спавн через интерфейс Discord-меню"""
    if amount < 1 or amount > 10:
        await interaction.response.send_message("❌ Нельзя спавнить меньше 1 или больше 10 объектов за раз.", ephemeral=True)
        return

    await interaction.response.defer()
    
    # Циклично создаем команду для спавна нужного количества
    cmd = ""
    for _ in range(amount):
        # Если это оружие/предмет — используем ent_create, если NPC — oc_spawn_npc
        if entity.startswith("npc_"):
            cmd += f"oc_spawn_npc {entity}; "
        else:
            cmd += f"ent_create {entity}; "

    await execute_rcon(cmd)
    await interaction.followup.send(f"🔮 На карту добавлено: **{entity}** в количестве **{amount} шт.**")

# =================================================================
# МОДУЛЬ 3: ПРЯМАЯ RCON КОНСОЛЬ (ДЛЯ АДМИНОВ)
# =================================================================

@bot.tree.command(name="rcon", description="[АДМИН] Отправить любую сырую команду в консоль сервера")
@app_commands.checks.has_permissions(administrator=True) # Доступ только админам Дискорда
@app_commands.describe(query="Текст команды (например: changelevel oc_harvest)")
async def rcon_console(interaction: discord.Interaction, query: str):
    """Позволяет управлять сервером на 100% без захода в игру"""
    await interaction.response.defer(ephemeral=True) # Ответ увидит только админ
    
    # Отправляем команду и забираем ответ логов из игры
    server_response = await execute_rcon(query)
    
    # Форматируем ответ в красивый блок кода
    formatted_response = f"```text\n{server_response}\n```"
    await interaction.followup.send(
        f"💻 **Запрос:** `{query}`\n**Ответ сервера:**\n{formatted_response}", 
        ephemeral=True
    )

# Обработка ошибок прав доступа
@rcon_console.error
async def rcon_error(interaction: discord.Interaction, error: app_commands.AppCommandError):
    if isinstance(error, app_commands.MissingPermissions):
        await interaction.response.send_message("⛔ У вас нет прав Администратора Discord для использования RCON.", ephemeral=True)

# Дописываем внутрь нашего существующего бота:

# Константы для аудио-анализа
CHANNELS = 2          # Стерео
SAMPLERATE = 44100    # Частота дискретизации Гц
CHUNK_SIZE = 2048     # Размер одного кусочка для анализа (~46 раз в секунду)
BYTES_PER_SAMPLE = 2  # 16-bit аудио
CHUNK_BYTES = CHUNK_SIZE * CHANNELS * BYTES_PER_SAMPLE

# Диапазон частот баса (в индексах FFT)
# При 44100Гц и чанке 2048 частотный шаг = 44100 / 2048 ≈ 21.5 Гц
# Индексы 1-6 соответствуют частотам ~21 Гц - 130 Гц (самый сочный бас)
BASS_MIN_IDX = 1
BASS_MAX_IDX = 6

# Порог чувствительности баса (подбирается экспериментально под треки)
# Если энергия баса выше этого значения — это удар (Beat)
BASS_THRESHOLD = 5000000.0  
COOLDOWN_TIME = 0.18  # Защита от дребезга (не спамить RCON чаще чем раз в 180мс)

last_beat_time = 0

async def trigger_server_beat(intensity: int):
    """Асинхронная отправка бита в игру. Вызывается из аудио-анализатора"""
    # Собираем пачку команд
    cmd = f"ent_fire beat_relay Trigger {intensity}"
    if intensity >= 4:
        cmd += "; ent_fire light_dance SetPattern z"
    else:
        cmd += "; ent_fire light_dance SetPattern m"
        
    # Просто вызываем нашу асинхронную функцию. 
    # Так как это фоновый ивент, мы не ждем ответа в чат Дискорда, но пускаем через await
    await execute_rcon(cmd)

# Модернизированная команда /play
@bot.tree.command(name="play", description="Запустить трек из VK с аудио-анализом физики")
async def play_vk_music_fft(interaction: discord.Interaction, url: str):
    await execute_rcon("ent_fire trigger_resume_music Trigger")
    await interaction.response.defer()
    await interaction.followup.send(f"🎵 **Запуск интерактива!** Анализирую басы в VK ролике:\n{url}")
    
    # Сложный пайплайн для ffmpeg:
    # 1. yt-dlp забирает поток из VK
    # 2. ffmpeg делит его на ДВА потока (с помощью tee):
    #    - Первый отправляется в Icecast как mp3 для игроков
    #    - Второй отдается в stdout как сырой PCM (16bit, 44100Hz) для нашего Python-скрипта
    cmd = (
        f"yt-dlp -o - \"{url}\" --format bestaudio | "
        f"ffmpeg -i pipe:0 -filter_complex \"asplit=2[out1][out2]\" "
        f"-map \"[out1]\" -acodec libmp3lame -ab 128k -f mp3 icecast://source:hackme_source@icecast-stream:8000/party.mp3 "
        f"-map \"[out2]\" -f s16le -ac 2 -ar 44100 pipe:1"
    )
    
    try:
        # Асинхронный запуск подпроцесса — теперь поток Discord-бота полностью свободен!
        process = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL
        )
        
        # Запускаем наш аудио-анализатор частот (FFT) как отдельную асинхронную задачу (Task)
        # Вместо threading.Thread теперь используем нативный asyncio loop
        task = asyncio.create_task(async_analyze_audio_stream(process))
        
           # Сообщаем игровому серверу через RCON о старте музыки
        stream_url = f"http://{SERVER_IP}:8000/party.mp3"
        await execute_rcon(f"oc_play_web_sound \"{stream_url}\"")
        # При запуске нового трека принудительно выключаем режим паники/тишины
        await execute_rcon("ent_fire trigger_resume_music Trigger")
        
    except Exception as e:
        print(f"Ошибка при асинхронном запуске медиа-потока: {e}")
        await interaction.followup.send("❌ Не удалось запустить обработку аудиопотока.")

# Асинхронная функция анализатора частот, адаптированная под asyncio.subprocess
async def async_analyze_audio_stream(process):
    global last_beat_time
    print("▶️ Асинхронный аудио-анализатор запущен. Слушаю частоты...")
    
    while True:
        # Асинхронное неблокирующее чтение фиксированного чанка байт из stdout
        raw_data = await process.stdout.read(CHUNK_BYTES)
        
        if not raw_data:
            print("⏹️ Аудиопоток завершен. Активирую режим ТИШИНЫ!")
            await execute_rcon("ent_fire trigger_silence Trigger") # Включаем хоррор-режим на ферме
            break
            
        # Математический анализ (FFT) выполняется мгновенно в CPU, его оставляем через numpy
        audio_data = np.frombuffer(raw_data, dtype=np.int16)
        
        if len(audio_data) == CHUNK_SIZE * 2:
            audio_data = (audio_data[0::2] + audio_data[1::2]) // 2
            
        fft_data = np.abs(np.fft.rfft(audio_data))
        bass_energy = np.sum(fft_data[BASS_MIN_IDX:BASS_MAX_IDX])
        
        current_time = time.time()
        if bass_energy > BASS_THRESHOLD and (current_time - last_beat_time) > COOLDOWN_TIME:
            last_beat_time = current_time
            intensity = int(min(max(bass_energy / BASS_THRESHOLD, 1), 5))
            
            # Отправляем триггер в игру
            trigger_server_beat(intensity)
            
# Запуск
bot.run(DISCORD_TOKEN, proxy="http://82.165.176.62:3128")
