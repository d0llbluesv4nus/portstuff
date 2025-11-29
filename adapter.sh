#!/bin/bash
set -e

GSI_DIR=$1
BASE_DIR=$2
WORK_DIR="$(pwd)/workspace"
OUT_DIR="$WORK_DIR/out"
MNT_SYS="$WORK_DIR/mnt_system"

mkdir -p "$OUT_DIR" "$MNT_SYS"

echo "=== GSI ADAPTER STARTED ==="

# 1. Обработка System Image (GSI)
SYS_IMG="$GSI_DIR/system.img"

if [ ! -f "$SYS_IMG" ]; then
    echo "❌ System image not found!"
    exit 1
fi

echo "Processing System Image..."
# Если образ sparse, разжимаем в raw для монтирования
if file "$SYS_IMG" | grep -q "sparse"; then
    simg2img "$SYS_IMG" "${SYS_IMG}.raw"
    mv "${SYS_IMG}.raw" "$SYS_IMG"
fi

# Увеличиваем размер образа для внесения правок (+200МБ)
e2fsck -f -y "$SYS_IMG" || true
resize2fs "$SYS_IMG" 4G || true

echo "Mounting GSI..."
sudo mount -t ext4 -o rw,loop "$SYS_IMG" "$MNT_SYS"

# --- ЗОНА ПРАВОК GSI ---

echo "🔧 Patching Build.prop (Spoofing)..."
# Подменяем пропсы, чтобы система думала, что она работает на Pixel (для Google Photos) 
# или на Alioth (для правильного определения железа)
PROP_FILES=("$MNT_SYS/system/build.prop" "$MNT_SYS/build.prop" "$MNT_SYS/system/phh/prop")

for prop in "${PROP_FILES[@]}"; do
    if [ -f "$prop" ]; then
        # Делаем систему "официальной"
        sudo sed -i 's/ro.build.type=.*/ro.build.type=user/' "$prop"
        sudo sed -i 's/ro.build.tags=.*/ro.build.tags=release-keys/' "$prop"
        # Отключаем Secure flag для работы ADB
        sudo sed -i 's/ro.secure=1/ro.secure=0/' "$prop"
        sudo sed -i 's/ro.adb.secure=1/ro.adb.secure=0/' "$prop"
        echo "Patched $prop"
    fi
done

echo "🔧 Ensuring Permissive Init..."
# GSI часто не грузятся, если Vendor требует специфичных прав.
# Создаем скрипт в init.d (если поддерживается) или правим rc
# Но самый надежный способ для GSI - это не system, а boot.img (CMDLINE).
# Здесь мы просто пытаемся отключить system-side проверки.
sudo rm -f "$MNT_SYS/system/recovery-from-boot.p"

# --- ФИКС ДЛЯ POCO F3 (OVERLAYS) ---
# Для GSI на Alioth критичны скругления и статусбар.
# Проверяем, есть ли папка phh (обычно есть в GSI)
if [ -d "$MNT_SYS/system/phh" ]; then
    echo "PHH directory found, activating Alioth specific tweaks if available..."
    # В GSI от PHH/TrebleDroid настройки часто уже внутри,
    # но можно положить свой overlay apk в /system/product/overlay/
fi

# -----------------------

echo "Unmounting System..."
sudo umount "$MNT_SYS"

# Сжимаем обратно в Sparse для уменьшения размера ZIP
echo "Sparsing System..."
img2simg "$SYS_IMG" "$OUT_DIR/system.img"

# 2. Копирование файлов от BASE
echo "Copying Base files..."
cp "$BASE_DIR/boot.img" "$OUT_DIR/" 2>/dev/null || echo "⚠️ Warning: boot.img not found"
cp "$BASE_DIR/vendor.img" "$OUT_DIR/" 2>/dev/null || echo "⚠️ Warning: vendor.img not found"
cp "$BASE_DIR/dtbo.img" "$OUT_DIR/" 2>/dev/null || true
cp "$BASE_DIR/vbmeta.img" "$OUT_DIR/" 2>/dev/null || true

# 3. Создание структуры для прошивки
# Вариант 1: Fastboot Images (проще и надежнее)
# Вариант 2: Recovery ZIP (нужен updater-script)

echo "Creating flashing script (Fastboot)..."
# Создаем батник/sh для удобной установки пользователем
cat <<EOF > "$OUT_DIR/flash_rom.sh"
#!/bin/bash
echo "Flashing POCO F3 Port..."
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vbmeta vbmeta.img
fastboot flash vendor vendor.img
fastboot flash system system.img
echo "Wiping userdata is recommended!"
echo "Done."
EOF

cat <<EOF > "$OUT_DIR/flash_rom.bat"
@echo off
echo Flashing POCO F3 Port...
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vbmeta vbmeta.img
fastboot flash vendor vendor.img
fastboot flash system system.img
echo Done. Format Data recommended.
pause
EOF

echo "=== ADAPTER FINISHED ==="
