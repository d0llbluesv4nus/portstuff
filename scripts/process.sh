#!/bin/bash

GSI_URL=$1
BOOT_URL=$2
ROM_NAME=$3

WORK_DIR=$(pwd)/build
INPUT_DIR=$WORK_DIR/input
MOUNT_POINT=$WORK_DIR/system_mount
OUTPUT_DIR=$WORK_DIR/output
TOOLS_DIR=$(pwd)/bin

mkdir -p $INPUT_DIR $MOUNT_POINT $OUTPUT_DIR $TOOLS_DIR

echo "=========================================="
echo "Starting GSI Patching for Poco F3"
echo "GSI: $GSI_URL"
echo "=========================================="

# --- 0. Подготовка инструментов (Magiskboot) ---
if [ ! -f "$TOOLS_DIR/magiskboot" ]; then
    echo "[!] Downloading Magiskboot..."
    wget https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz -O temp_pd.tar.gz
    # Для простоты используем готовую сборку magiskboot с GitHub (пример)
    wget https://raw.githubusercontent.com/yshalsager/magiskboot_build_script/master/magiskboot -O "$TOOLS_DIR/magiskboot"
    chmod +x "$TOOLS_DIR/magiskboot"
fi
export PATH=$TOOLS_DIR:$PATH

# --- 1. Скачивание файлов ---
echo "[+] Downloading GSI..."
axel -n 16 -o "$INPUT_DIR/system_archive" "$GSI_URL" || wget -O "$INPUT_DIR/system_archive" "$GSI_URL"

echo "[+] Downloading Boot image..."
wget -O "$INPUT_DIR/boot.img" "$BOOT_URL"

# --- 2. Распаковка GSI ---
echo "[+] Extracting GSI..."
cd "$INPUT_DIR"
# Проверка типа архива
if [[ "$GSI_URL" == *.xz ]]; then
    xz -d -c system_archive > system.img
elif [[ "$GSI_URL" == *.zip ]]; then
    unzip system_archive
    # Ищем system.img внутри
    find . -name "system.img" -exec mv {} . \;
else
    mv system_archive system.img
fi

# Проверка, является ли образ sparse, и конвертация в raw
if file system.img | grep -q "sparse"; then
    echo "[+] Converting Sparse to Raw..."
    simg2img system.img system_raw.img
    mv system_raw.img system.img
fi

# --- 3. Работа с System (Конвертация и Патчинг) ---
echo "[+] Checking filesystem type..."
FS_TYPE=$(file -sL system.img | grep -oE 'ext4|erofs')

if [ "$FS_TYPE" == "erofs" ]; then
    echo "[!] EROFS detected. Extracting and converting to EXT4 for modification..."
    # EROFS - только чтение. Нужно распаковать и создать новый EXT4 образ.
    extract.erofs -i system.img -x
    # Теперь файлы в папке "extract" (или аналогичной, зависит от версии утилиты, часто это просто корень)
    # Предположим extract.erofs распаковал в ./system
    # Если extract.erofs не сработал как надо (зависит от версии), используем mount
    mkdir -p raw_system
    extract.erofs -i system.img -o raw_system
    
    # Создаем новый ext4 образ нужного размера (например 4Гб)
    make_ext4fs -s -l 4096M -a system new_system.img raw_system/
    mv new_system.img system.img
    
    # Чистим
    rm -rf raw_system
fi

echo "[+] Mounting System..."
sudo mount -o loop,rw system.img "$MOUNT_POINT"

# === ПАТЧИНГ SYSTEM ===

echo "[*] Enabling USB Debugging (ADB)..."
# Добавляем свойства в build.prop (или system/build.prop)
PROP_FILE="$MOUNT_POINT/system/build.prop"
if [ ! -f "$PROP_FILE" ]; then PROP_FILE="$MOUNT_POINT/build.prop"; fi

sudo bash -c "echo '' >> $PROP_FILE"
sudo bash -c "echo '# Enable ADB' >> $PROP_FILE"
sudo bash -c "echo 'persist.sys.usb.config=mtp,adb' >> $PROP_FILE"
sudo bash -c "echo 'ro.adb.secure=0' >> $PROP_FILE"
sudo bash -c "echo 'ro.debuggable=1' >> $PROP_FILE"
sudo bash -c "echo 'service.adb.root=1' >> $PROP_FILE"

echo "[*] Applying Overlays (Poco F3 specific)..."
# Копируем оверлеи из папки репозитория (если они есть)
if [ -d "$(pwd)/../../patches/overlays" ]; then
    OVERLAY_DIR="$MOUNT_POINT/system/product/overlay"
    sudo mkdir -p "$OVERLAY_DIR"
    sudo cp -r $(pwd)/../../patches/overlays/* "$OVERLAY_DIR/"
    echo "[+] Overlays copied."
else
    echo "[!] No overlays found in patches/overlays/"
fi

echo "[*] Patching Fstab (Generic)..."
# Обычно в GSI fstab лежит в boot, но иногда есть и в system/etc
# Удаляем шифрование или verity, если нужно (пример)
# sudo sed -i 's/fileencryption=//g' "$MOUNT_POINT/system/etc/fstab*" 2>/dev/null || true

# Размонтирование
sudo umount "$MOUNT_POINT"

# Уменьшение размера образа ext4 до минимального
e2fsck -f -y system.img
resize2fs -M system.img

# --- 4. Работа с Boot (Patcher) ---
echo "[+] Patching Boot Image..."
cd "$INPUT_DIR"
mkdir boot_work
cp boot.img boot_work/
cd boot_work

# Распаковка boot
"$TOOLS_DIR/magiskboot" unpack boot.img

echo "[*] Editing Ramdisk properties..."
# Если cpio распакован успешно (обычно ramdisk.cpio)
"$TOOLS_DIR/magiskboot" cpio ramdisk.cpio extract

# Включение отладки в default.prop (находится в корне ramdisk)
if [ -f "default.prop" ]; then
    sed -i 's/ro.adb.secure=1/ro.adb.secure=0/' default.prop
    sed -i 's/ro.debuggable=0/ro.debuggable=1/' default.prop
    echo "persist.sys.usb.config=mtp,adb" >> default.prop
fi

# Патчинг fstab в ramdisk (если он там есть)
# Alioth использует system-as-root, поэтому основной fstab часто в vendor, 
# но ранний fstab в ramdisk. Удаляем проверку vbmeta.
for f in fstab.*; do
    [ -e "$f" ] || continue
    sed -i 's/,avb_keys=[^,]*//g' "$f"
    sed -i 's/,avb=[^,]*//g' "$f"
    sed -i 's/,verify//g' "$f"
done

# Запаковка ramdisk обратно
"$TOOLS_DIR/magiskboot" cpio ramdisk.cpio patch
"$TOOLS_DIR/magiskboot" cpio ramdisk.cpio repack "ramdisk_new.cpio"
mv ramdisk_new.cpio ramdisk.cpio

echo "[*] Repacking Boot..."
"$TOOLS_DIR/magiskboot" repack boot.img
mv new-boot.img ../patched_boot.img
cd ..

# --- 5. Финальная упаковка ---
echo "[+] Zipping final ROM..."
mv system.img system_patched.img
zip -r "$OUTPUT_DIR/${ROM_NAME}.zip" system_patched.img patched_boot.img

echo "=========================================="
echo "Done! Output: $OUTPUT_DIR/${ROM_NAME}.zip"
echo "=========================================="