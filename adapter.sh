#!/bin/bash
set -e

GSI_DIR=$1
BASE_DIR=$2
WORK_DIR="$(pwd)/workspace"
OUT_DIR="$WORK_DIR/out"
MNT_SYS="$WORK_DIR/mnt_system"

mkdir -p "$OUT_DIR" "$MNT_SYS"

echo "=== GSI ADAPTER (Universal) STARTED ==="

# --- 1. GSI PROCESSING ---
SYS_IMG="$GSI_DIR/system.img"
if [ ! -f "$SYS_IMG" ]; then echo "❌ No system.img"; exit 1; fi

if file "$SYS_IMG" | grep -q "sparse"; then
    simg2img "$SYS_IMG" "${SYS_IMG}.raw"
    mv "${SYS_IMG}.raw" "$SYS_IMG"
fi
e2fsck -f -y "$SYS_IMG" || true
resize2fs "$SYS_IMG" 4G || true

echo "Mounting System..."
sudo mount -t ext4 -o rw,loop "$SYS_IMG" "$MNT_SYS"

echo "Patching Props..."
# Стандартные патчи
for prop in "$MNT_SYS/system/build.prop" "$MNT_SYS/build.prop"; do
    if [ -f "$prop" ]; then
        sudo sed -i 's/ro.boot.dynamic_partitions=.*/ro.boot.dynamic_partitions=true/' "$prop"
        sudo sed -i 's/ro.secure=1/ro.secure=0/' "$prop"
        sudo sed -i 's/ro.adb.secure=1/ro.adb.secure=0/' "$prop"
    fi
done
sudo rm -f "$MNT_SYS/system/recovery-from-boot.p"
sudo umount "$MNT_SYS"

echo "Optimizing GSI..."
img2simg "$SYS_IMG" "$OUT_DIR/system.img"

# --- 2. BASE FILES PROCESSING ---
echo "Copying Base files..."

# Функция для поиска файла (потому что lpunpack может дать vendor_a.img или vendor.img)
find_and_copy() {
    NAME=$1
    # Ищем: vendor.img, vendor_a.img, vendor_b.img
    FILE=$(find "$BASE_DIR" -name "${NAME}.img" -o -name "${NAME}_a.img" | head -n 1)
    if [ ! -z "$FILE" ]; then
        echo "Found $NAME at $FILE"
        cp "$FILE" "$OUT_DIR/${NAME}.img"
    else
        echo "⚠️ Warning: $NAME not found in Base"
    fi
}

find_and_copy "boot"
find_and_copy "dtbo"
find_and_copy "vbmeta"
find_and_copy "vendor"
find_and_copy "product"
find_and_copy "odm"

# --- 3. GENERATE SCRIPTS ---
echo "Generating FastbootD scripts..."

cat <<EOF > "$OUT_DIR/flash_rom.bat"
@echo off
echo POCO F3 FastbootD Flasher
pause
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vbmeta vbmeta.img --disable-verity --disable-verification
echo Rebooting to FastbootD...
fastboot reboot fastboot
timeout /t 10
fastboot flash vendor vendor.img
fastboot flash system system.img
if exist product.img fastboot flash product product.img
if exist odm.img fastboot flash odm odm.img
fastboot reboot
pause
EOF

cat <<EOF > "$OUT_DIR/flash_rom.sh"
#!/bin/bash
echo "POCO F3 FastbootD Flasher"
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vbmeta vbmeta.img --disable-verity --disable-verification
echo "Rebooting to FastbootD..."
fastboot reboot fastboot
sleep 10
fastboot flash vendor vendor.img
fastboot flash system system.img
[ -f product.img ] && fastboot flash product product.img
[ -f odm.img ] && fastboot flash odm odm.img
fastboot reboot
EOF
chmod +x "$OUT_DIR/flash_rom.sh"

echo "=== DONE ==="
