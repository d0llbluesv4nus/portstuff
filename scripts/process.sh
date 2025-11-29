#!/bin/bash

GSI_URL=$1
ROM_NAME=$2

WORK_DIR=$(pwd)/build
INPUT_DIR=$WORK_DIR/input
MOUNT_POINT=$WORK_DIR/system_mount
OUTPUT_DIR=$WORK_DIR/output

mkdir -p $INPUT_DIR $MOUNT_POINT $OUTPUT_DIR

echo "=========================================="
echo "Starting GSI System Patching"
echo "Target Device: Poco F3 (Alioth)"
echo "Source GSI: $GSI_URL"
echo "=========================================="

# --- 1. Скачивание GSI ---
echo "[+] Downloading GSI..."
# Используем axel для скорости, fallback на wget
axel -n 16 -o "$INPUT_DIR/system_archive" "$GSI_URL" || wget -O "$INPUT_DIR/system_archive" "$GSI_URL"

# --- 2. Распаковка и подготовка образа ---
cd "$INPUT_DIR"
echo "[+] Extracting GSI..."

if [[ "$GSI_URL" == *.xz ]]; then
    xz -d -c system_archive > system.img
elif [[ "$GSI_URL" == *.zip ]]; then
    unzip system_archive
    # Ищем system.img, так как в ZIP он может называться по-разному
    find . -name "system.img" -exec mv {} . \;
else
    mv system_archive system.img
fi

# Если файл не назвался system.img (например, system-arm64-ab.img), переименуем
if [ ! -f system.img ]; then
    find . -maxdepth 1 -name "*.img" -head 1 -exec mv {} system.img \;
fi

# Проверка на Sparse формат (если образ сжат для прошивки)
if file system.img | grep -q "sparse"; then
    echo "[+] Converting Sparse to Raw..."
    simg2img system.img system_raw.img
    mv system_raw.img system.img
fi

# --- 3. Конвертация EROFS -> EXT4 (если нужно) ---
# Большинство Android 13/14 GSI идут в EROFS (Read-Only). Нам нужен EXT4 (Read-Write).
FS_TYPE=$(file -sL system.img | grep -oE 'ext4|erofs')
echo "[+] Filesystem detected: $FS_TYPE"

if [ "$FS_TYPE" == "erofs" ]; then
    echo "[!] Converting EROFS to EXT4 for modding..."
    # Распаковываем EROFS
    extract.erofs -i system.img -x
    
    # Ищем, куда распаковалось (обычно папка extract или корень)
    # Предполагаем, что rootfs лежит в текущей директории, если extract.erofs так настроен
    # Но для надежности создадим структуру
    if [ -d "extract" ]; then
        SOURCE_DIR="extract"
    else
        # Если старая версия утилиты распаковала в корень
        mkdir -p extracted_root
        extract.erofs -i system.img -o extracted_root
        SOURCE_DIR="extracted_root"
    fi
    
    # Создаем EXT4 образ с запасом места (например, 4.5ГБ)
    make_ext4fs -s -l 4608M -a system new_system.img "$SOURCE_DIR/"
    mv new_system.img system.img
    rm -rf "$SOURCE_DIR"
elif [ "$FS_TYPE" == "ext4" ]; then
    # Если уже ext4, просто увеличиваем размер, чтобы влезли патчи
    e2fsck -f -y system.img
    resize2fs system.img 5000M
fi

# --- 4. Монтирование ---
echo "[+] Mounting System Image..."
sudo mount -o loop,rw system.img "$MOUNT_POINT"

# --- 5. Внесение изменений (ПАТЧИНГ) ---

# A. Включение USB Debugging (ADB)
echo "[*] Enabling ADB in build.prop..."
# Файл может лежать в system/build.prop или в корне (system-as-root)
PROP_FILE="$MOUNT_POINT/system/build.prop"
if [ ! -f "$PROP_FILE" ]; then PROP_FILE="$MOUNT_POINT/build.prop"; fi

if [ -f "$PROP_FILE" ]; then
    sudo bash -c "echo '' >> $PROP_FILE"
    sudo bash -c "echo '# MODS BY GITHUB ACTIONS' >> $PROP_FILE"
    # Принудительное включение отладки
    sudo bash -c "echo 'persist.sys.usb.config=mtp,adb' >> $PROP_FILE"
    sudo bash -c "echo 'ro.adb.secure=0' >> $PROP_FILE"
    sudo bash -c "echo 'ro.debuggable=1' >> $PROP_FILE"
    sudo bash -c "echo 'service.adb.root=1' >> $PROP_FILE"
    
    # Спуфинг (опционально, чтобы проходить SafetyNet базово)
    # sudo sed -i 's/ro.build.type=userdebug/ro.build.type=user/' $PROP_FILE
else
    echo "[!] Warning: build.prop not found!"
fi

# B. Установка Оверлеев (Poco F3 Overlays)
echo "[*] Injecting Overlays..."
OVERLAY_SOURCE="$(pwd)/../../patches/overlays"
OVERLAY_TARGET="$MOUNT_POINT/system/product/overlay"

if [ -d "$OVERLAY_SOURCE" ]; then
    # Создаем папку, если её нет
    sudo mkdir -p "$OVERLAY_TARGET"
    sudo cp -r "$OVERLAY_SOURCE"/* "$OVERLAY_TARGET/"
    
    # Выставляем права 644
    sudo chmod 644 "$OVERLAY_TARGET"/*.apk 2>/dev/null || true
    echo "[+] Overlays installed."
else
    echo "[!] No overlays found in repository (patches/overlays). Skipping."
fi

# C. Патчинг Fstab (В GSI fstab часто находится в /system/etc/)
echo "[*] Patching fstab inside system (if exists)..."
# Ищем файлы fstab
FSTAB_FILES=$(find "$MOUNT_POINT/system/etc" -name "fstab*")
for f in $FSTAB_FILES; do
    echo "   -> Patching $f"
    # Убираем forceencrypt или fileencryption, меняем на encryptable (опционально)
    # sudo sed -i 's/fileencryption=/encryptable=/' "$f"
    
    # Часто нужно убрать verify (AVB) чтобы система загрузилась с изменениями
    sudo sed -i 's/,verify//g' "$f"
    sudo sed -i 's/,avb=[^,]*//g' "$f"
done

# D. Phh / Treble Settings (Если это Phh-based GSI)
# Иногда нужно создать флаг-файлы, чтобы активировать фиксы для Xiaomi
# Пример: включение альтернативного режима подсветки, если нужно
# sudo touch "$MOUNT_POINT/system/phh/xiaomi-new-brightness-scale"

# --- 6. Завершение ---
echo "[+] Unmounting and shrinking..."
sudo umount "$MOUNT_POINT"

# Уменьшаем размер образа до минимально возможного, чтобы ZIP был меньше
e2fsck -f -y system.img
resize2fs -M system.img

echo "[+] Zipping Result..."
mv system.img system_patched.img
zip -r "$OUTPUT_DIR/${ROM_NAME}.zip" system_patched.img

echo "=========================================="
echo "Done! File saved to artifacts."
echo "=========================================="
