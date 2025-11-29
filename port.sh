#!/bin/bash
set -e

SOURCE_DIR=$1
BASE_DIR=$2
WORK_DIR="$(pwd)/workspace"
OUT_DIR="$WORK_DIR/out"
MNT_SYS="$WORK_DIR/mnt_system"
MNT_BASE_VEN="$WORK_DIR/mnt_base_vendor"

mkdir -p "$OUT_DIR" "$MNT_SYS" "$MNT_BASE_VEN"

echo "=== STARTING PORTING PROCESS ==="

# --- 1. FIND & PREPARE SYSTEM IMAGE (SOURCE) ---
# Ищем system, system_a, system_root...
SYS_IMG=$(find "$SOURCE_DIR" -name "system.img" -o -name "system_a.img" -o -name "system_root.img" | head -n 1)

if [ -z "$SYS_IMG" ]; then
    echo "❌ CRITICAL: System image not found in Source!"
    # Листинг для отладки
    ls -R "$SOURCE_DIR"
    exit 1
fi

echo "Found System: $SYS_IMG"

# Convert Sparse -> Raw
if file "$SYS_IMG" | grep -q "sparse"; then
    echo "Desparsing system..."
    simg2img "$SYS_IMG" "${SYS_IMG}.raw"
    mv "${SYS_IMG}.raw" "$SYS_IMG"
fi

# Resize + Mount
e2fsck -f -y "$SYS_IMG" || true
resize2fs "$SYS_IMG" 5G || true
echo "Mounting System..."
sudo mount -t ext4 -o rw,loop "$SYS_IMG" "$MNT_SYS"


# --- 2. FIND BASE VENDOR (FOR FSTAB) ---
# Нам нужен fstab от Poco F3, он лежит в vendor/etc/fstab.qcom
VEN_IMG=$(find "$BASE_DIR" -name "vendor.img" -o -name "vendor_a.img" | head -n 1)

if [ -z "$VEN_IMG" ]; then
    echo "❌ CRITICAL: Vendor image not found in Base!"
    exit 1
fi

if file "$VEN_IMG" | grep -q "sparse"; then
    simg2img "$VEN_IMG" "${VEN_IMG}.raw"
    mv "${VEN_IMG}.raw" "$VEN_IMG"
fi
echo "Mounting Base Vendor..."
sudo mount -t ext4 -o ro,loop "$VEN_IMG" "$MNT_BASE_VEN"


# --- 3. APPLYING FIXES (THE "PORTING") ---

echo "🔧 Replacing Fstab..."
# Удаляем старый fstab из системы
sudo rm -f "$MNT_SYS/system/etc/fstab"*
sudo rm -f "$MNT_SYS/system/vendor/etc/fstab"* 2>/dev/null || true

# Копируем родной fstab от Poco F3
if [ -f "$MNT_BASE_VEN/etc/fstab.qcom" ]; then
    sudo cp "$MNT_BASE_VEN/etc/fstab.qcom" "$MNT_SYS/system/etc/fstab.qcom"
    echo "✅ Fstab replaced from Base Vendor."
else
    echo "⚠️ Warning: Could not find fstab in base vendor. Using generic."
fi

echo "🔧 Patching build.prop..."
for prop in "$MNT_SYS/system/build.prop" "$MNT_SYS/build.prop"; do
    if [ -f "$prop" ]; then
        # Важно для совместимости с Vendor
        sudo sed -i 's/ro.product.device=.*/ro.product.device=alioth/' "$prop"
        sudo sed -i 's/ro.product.model=.*/ro.product.model=M2012K11AC/' "$prop"
        # Разрешаем динамические разделы
        sudo sed -i 's/ro.boot.dynamic_partitions=.*/ro.boot.dynamic_partitions=true/' "$prop"
        # Отключаем проверки
        sudo sed -i 's/ro.secure=1/ro.secure=0/' "$prop"
        sudo sed -i 's/ro.adb.secure=1/ro.adb.secure=0/' "$prop"
    fi
done

echo "🔧 Disabling AVB/Verity in Init..."
# Чтобы ядро не паниковало при изменении system
find "$MNT_SYS/system/etc/init" -name "*.rc" -type f | while read rc; do
    sudo sed -i '/verify/d' "$rc"
    sudo sed -i '/avb/d' "$rc"
done

# Удаляем скрипт восстановления сток рекавери
sudo rm -f "$MNT_SYS/system/recovery-from-boot.p"

# --- 4. FINALIZE IMAGES ---

echo "Unmounting..."
sudo umount "$MNT_SYS"
sudo umount "$MNT_BASE_VEN"

echo "Optimizing System..."
img2simg "$SYS_IMG" "$OUT_DIR/system.img"


# --- 5. COLLECTING FILES FOR FLASHING ---
echo "Copying Firmware Files..."

# Функция копирования с поиском
copy_img() {
    NAME=$1
    # Ищем файл в Base, игнорируя суффиксы _a
    FILE=$(find "$BASE_DIR" -name "${NAME}.img" -o -name "${NAME}_a.img" | head -n 1)
    if [ ! -z "$FILE" ]; then
        cp "$FILE" "$OUT_DIR/${NAME}.img"
        echo "✅ Added $NAME"
    else
        echo "⚠️ Missing $NAME"
    fi
}

copy_img "boot"
copy_img "dtbo"
copy_img "vbmeta"
copy_img "vendor"
# Иногда нужны product/odm если они есть в базе
copy_img "product"
copy_img "odm"


# --- 6. CREATE INSTALLER SCRIPTS (FASTBOOTD) ---
echo "Creating FastbootD Flashers..."

cat <<EOF > "$OUT_DIR/flash_rom.bat"
@echo off
echo =========================================
echo    POCO F3 Custom Port Flasher
echo =========================================
pause

echo [1/3] Flashing Physical partitions...
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vbmeta vbmeta.img --disable-verity --disable-verification

echo [2/3] Rebooting to FASTBOOTD (Userpsace)...
fastboot reboot fastboot
timeout /t 10

echo [3/3] Flashing Dynamic partitions...
fastboot flash vendor vendor.img
fastboot flash system system.img
if exist product.img fastboot flash product product.img
if exist odm.img fastboot flash odm odm.img

echo Done. Formatting Data is recommended!
fastboot reboot
pause
EOF

cat <<EOF > "$OUT_DIR/flash_rom.sh"
#!/bin/bash
echo "=== POCO F3 Custom Port Flasher ==="
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vbmeta vbmeta.img --disable-verity --disable-verification

echo "Rebooting to FASTBOOTD..."
fastboot reboot fastboot
sleep 10

fastboot flash vendor vendor.img
fastboot flash system system.img
[ -f product.img ] && fastboot flash product product.img
[ -f odm.img ] && fastboot flash odm odm.img

echo "Done."
fastboot reboot
EOF

chmod +x "$OUT_DIR/flash_rom.sh"
echo "=== PORTING FINISHED SUCCESSFULLY ==="
