#!/bin/bash
set -e

GSI_DIR=$1
BASE_DIR=$2
WORK_DIR="$(pwd)/workspace"
OUT_DIR="$WORK_DIR/out"
MNT_SYS="$WORK_DIR/mnt_system"

mkdir -p "$OUT_DIR" "$MNT_SYS"

echo "=== GSI ADAPTER (POCO F3 SUPER EDITION) STARTED ==="

# 1. ОБРАБОТКА SYSTEM (GSI)
SYS_IMG="$GSI_DIR/system.img"
if [ ! -f "$SYS_IMG" ]; then
    echo "❌ Error: System image not found!"
    exit 1
fi

echo "Processing System Image..."
# Если GSI сжат в sparse (android format), разжимаем для монтирования
if file "$SYS_IMG" | grep -q "sparse"; then
    simg2img "$SYS_IMG" "${SYS_IMG}.raw"
    mv "${SYS_IMG}.raw" "$SYS_IMG"
fi

# Расширяем образ (Poco F3 system раздел в super довольно большой, даем запас)
e2fsck -f -y "$SYS_IMG" || true
resize2fs "$SYS_IMG" 4G || true

echo "Mounting System..."
sudo mount -t ext4 -o rw,loop "$SYS_IMG" "$MNT_SYS"

# --- ПРАВКИ ---
echo "🔧 Patching Props..."
for prop in "$MNT_SYS/system/build.prop" "$MNT_SYS/build.prop"; do
    if [ -f "$prop" ]; then
        # Важно для Super раздела: разрешаем логические разделы
        sudo sed -i 's/ro.boot.dynamic_partitions=.*/ro.boot.dynamic_partitions=true/' "$prop"
        # Фиксы безопасности
        sudo sed -i 's/ro.secure=1/ro.secure=0/' "$prop"
        sudo sed -i 's/ro.adb.secure=1/ro.adb.secure=0/' "$prop"
    fi
done

# Удаляем recovery-from-boot, чтобы не затереть TWRP
sudo rm -f "$MNT_SYS/system/recovery-from-boot.p"

echo "Unmounting System..."
sudo umount "$MNT_SYS"

echo "Optimizing System Image (Sparse)..."
img2simg "$SYS_IMG" "$OUT_DIR/system.img"


# 2. КОПИРОВАНИЕ ФАЙЛОВ ОТ BASE (ИЗ SUPER РАЗДЕЛА)
echo "Copying Base files..."

# Boot и Vbmeta шьются в физические разделы
cp "$BASE_DIR/boot.img" "$OUT_DIR/" 2>/dev/null || echo "⚠️ boot.img missing"
cp "$BASE_DIR/vbmeta.img" "$OUT_DIR/" 2>/dev/null || echo "⚠️ vbmeta.img missing"
cp "$BASE_DIR/dtbo.img" "$OUT_DIR/" 2>/dev/null || echo "⚠️ dtbo.img missing"

# Vendor, Product, Odm - это ЛОГИЧЕСКИЕ разделы внутри Super
# Мы берем их готовыми от базы
cp "$BASE_DIR/vendor.img" "$OUT_DIR/" 2>/dev/null || echo "⚠️ vendor.img missing"
# Если в базе есть product или odm, копируем их тоже (в MIUI они есть)
cp "$BASE_DIR/product.img" "$OUT_DIR/" 2>/dev/null || true
cp "$BASE_DIR/odm.img" "$OUT_DIR/" 2>/dev/null || true


# 3. ГЕНЕРАЦИЯ СКРИПТА ПРОШИВКИ (ДЛЯ SUPER PARTITION)
echo "Creating FastbootD flashing scripts..."

# --- WINDOWS (.bat) ---
cat <<EOF > "$OUT_DIR/flash_rom.bat"
@echo off
echo ==============================================
echo      POCO F3 (Alioth) Automated Flasher
echo      For Dynamic Partitions (Super)
echo ==============================================
pause

echo 1. Flashing Physical Partitions (Bootloader mode)...
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vbmeta vbmeta.img --disable-verity --disable-verification

echo.
echo 2. Rebooting into FASTBOOTD (Userspace) for Super partitions...
echo Please wait, the screen will change...
fastboot reboot fastboot
timeout /t 10

echo.
echo 3. Flashing Logical Partitions to Super...
echo Flashing Vendor...
fastboot flash vendor vendor.img
echo Flashing System...
fastboot flash system system.img

if exist product.img (
    echo Flashing Product...
    fastboot flash product product.img
)
if exist odm.img (
    echo Flashing ODM...
    fastboot flash odm odm.img
)

echo.
echo 4. Rebooting to System...
fastboot reboot
echo Done. If bootloop -> Format Data in Recovery.
pause
EOF

# --- LINUX/MAC (.sh) ---
cat <<EOF > "$OUT_DIR/flash_rom.sh"
#!/bin/bash
echo "=== POCO F3 Flasher (FastbootD) ==="

echo "[1/4] Flashing Physical partitions..."
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vbmeta vbmeta.img --disable-verity --disable-verification

echo "[2/4] Rebooting to FASTBOOTD..."
fastboot reboot fastboot
sleep 8

echo "[3/4] Flashing Logical partitions (Super)..."
fastboot flash vendor vendor.img
fastboot flash system system.img
[ -f product.img ] && fastboot flash product product.img
[ -f odm.img ] && fastboot flash odm odm.img

echo "[4/4] Rebooting..."
fastboot reboot
EOF

chmod +x "$OUT_DIR/flash_rom.sh"
echo "=== ADAPTER FINISHED ==="
