#!/bin/bash

# Остановка при ошибках
set -e

GSI_URL=$1
ROM_NAME=$2

# Рабочие директории
WORK_DIR=$(pwd)/build
INPUT_DIR=$WORK_DIR/input
MOUNT_POINT=$WORK_DIR/system_mount
OUTPUT_DIR=$WORK_DIR/output
OVERLAY_BUILD_DIR=$WORK_DIR/overlay_gen

mkdir -p $INPUT_DIR $MOUNT_POINT $OUTPUT_DIR $OVERLAY_BUILD_DIR

echo "=========================================="
echo "Starting OneUI 7 GSI Patcher for Poco F3"
echo "Target: Samsung OneUI Port on Alioth"
echo "Source: $GSI_URL"
echo "=========================================="

# --- 0. УСТАНОВКА ИНСТРУМЕНТОВ (Если запускается локально, а не в CI) ---
# В GitHub Actions это обычно делается в workflow, но добавим для надежности
if ! command -v extract.erofs &> /dev/null; then
    echo "[!] Installing tools..."
    sudo apt-get update
    sudo apt-get install -y git wget unzip zip tar axel python3 android-sdk-libsparse-utils e2fsprogs simg2img erofs-utils aapt apksigner openjdk-11-jdk
fi

# ==========================================
# 1. ГЕНЕРАЦИЯ ОВЕРЛЕЯ (FIXED VERSION)
# ==========================================
echo "[+] Generating Poco F3 Overlay (Alioth)..."
mkdir -p $OVERLAY_BUILD_DIR/res/values

# AndroidManifest.xml
cat <<EOF > $OVERLAY_BUILD_DIR/AndroidManifest.xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="me.phh.treble.overlay.xiaomi.alioth"
    android:versionCode="1"
    android:versionName="1.0">
    <overlay android:isStatic="true" android:priority="999" android:targetPackage="android" />
</manifest>
EOF

# config.xml (Без дубликатов!)
cat <<EOF > $OVERLAY_BUILD_DIR/res/values/config.xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Основные настройки -->
    <bool name="config_showNavigationBar">true</bool>
    <string name="config_mainBuiltInDisplayCutout">M 540,35 a 35,35 0 1,0 0,70 a 35,35 0 1,0 0,-70 Z</string>
    <bool name="config_fillMainBuiltInDisplayCutout">true</bool>
    <bool name="config_automatic_brightness_available">true</bool>
    <integer name="config_screenBrightnessSettingMinimum">1</integer>
    <integer name="config_screenBrightnessSettingMaximum">1023</integer>
    <integer name="config_screenBrightnessDoze">17</integer>
    <integer name="config_defaultRefreshRate">120</integer>
    <integer name="config_defaultPeakRefreshRate">120</integer>
    <bool name="config_fingerprintSupportsGestures">true</bool>
</resources>
EOF

# dimens.xml (Размеры и скругления)
cat <<EOF > $OVERLAY_BUILD_DIR/res/values/dimens.xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <dimen name="status_bar_height">38dp</dimen>
    <dimen name="status_bar_height_portrait">38dp</dimen>
    <dimen name="status_bar_height_landscape">24dp</dimen>
    <dimen name="rounded_corner_radius">110px</dimen>
    <dimen name="rounded_corner_radius_top">110px</dimen>
    <dimen name="rounded_corner_radius_bottom">110px</dimen>
</resources>
EOF

# Компиляция Оверлея
echo "[.] Compiling Overlay..."
# Используем локальный android.jar из GitHub Actions
ANDROID_JAR="$ANDROID_SDK_ROOT/platforms/android-34/android.jar"
if [ ! -f "$ANDROID_JAR" ]; then
    ANDROID_JAR="$ANDROID_SDK_ROOT/platforms/android-33/android.jar"
fi

if [ -f "$ANDROID_JAR" ]; then
    cd $OVERLAY_BUILD_DIR
    aapt package -f -M AndroidManifest.xml -S res -I "$ANDROID_JAR" -F unaligned.apk --min-sdk-version 29 --target-sdk-version 30
    
    # Генерация ключа и подпись
    keytool -genkey -v -keystore test.keystore -alias test -keyalg RSA -keysize 2048 -validity 10000 -storepass password -keypass password -dname "CN=Android Debug,O=Android,C=US"
    apksigner sign --ks test.keystore --ks-pass pass:password --out treble_overlay_xiaomi_alioth.apk unaligned.apk
    
    OVERLAY_PATH="$OVERLAY_BUILD_DIR/treble_overlay_xiaomi_alioth.apk"
    echo "[+] Overlay compiled successfully: $OVERLAY_PATH"
    cd $WORK_DIR
else
    echo "[!] ERROR: android.jar not found! Skipping overlay generation (BOOTLOOP RISK)."
fi

# ==========================================
# 2. СКАЧИВАНИЕ И РАСПАКОВКА GSI
# ==========================================
echo "[+] Downloading GSI..."
# Скачиваем axel (быстро) или wget
mkdir -p "$INPUT_DIR"
cd "$INPUT_DIR"
axel -n 16 -o "gsi_rom.zip" "$GSI_URL" || wget -O "gsi_rom.zip" "$GSI_URL"

echo "[+] Extracting..."
unzip "gsi_rom.zip"
# Находим system.img (иногда он внутри xz или называется иначе)
find . -name "*.xz" -exec xz -d {} \;
find . -name "*.img" ! -name "system.img" -exec mv {} system.img \;

# Проверка на Sparse (simg)
if file system.img | grep -q "sparse"; then
    echo "[.] Converting Sparse to Raw..."
    simg2img system.img system_raw.img
    mv system_raw.img system.img
fi

# ==========================================
# 3. КОНВЕРТАЦИЯ EROFS -> EXT4 (RW)
# ==========================================
FS_TYPE=$(file -sL system.img | grep -oE 'ext4|erofs')
echo "[+] Filesystem is: $FS_TYPE"

if [ "$FS_TYPE" == "erofs" ]; then
    echo "[!] EROFS detected. Unpacking..."
    # Распаковываем EROFS
    extract.erofs -i system.img -x
    
    # Ищем куда распаковалось (обычно папка extract или корень)
    if [ -d "extract" ]; then ROOT_SRC="extract"; else ROOT_SRC="."; fi
    
    echo "[.] Creating new EXT4 image (Writable)..."
    # Создаем образ с запасом места (7GB должно хватить для OneUI)
    # make_ext4fs -s -l 7168M -a system new_system.img "$ROOT_SRC/" 
    # В Ubuntu 22.04 лучше использовать mkfs.ext4
    
    dd if=/dev/zero of=new_system.img bs=1M count=7168
    mkfs.ext4 new_system.img
    
    # Монтируем оба для копирования
    mkdir -p mnt_new
    sudo mount -o loop new_system.img mnt_new
    
    echo "[.] Copying files to new image..."
    if [ -d "extract" ]; then
        sudo cp -av extract/* mnt_new/
    else
        # Если распаковалось в корень, нужно копировать аккуратно, пропуская system.img
        sudo rsync -av --exclude='system.img' --exclude='new_system.img' --exclude='gsi_rom.zip' ./ mnt_new/
    fi
    
    sudo umount mnt_new
    mv new_system.img system.img
    rm -rf extract
fi

# ==========================================
# 4. МОНТИРОВАНИЕ И ПАТЧИНГ
# ==========================================
echo "[+] Mounting System RW..."
sudo mount -o loop,rw system.img "$MOUNT_POINT"

# --- A. УСТАНОВКА ОВЕРЛЕЯ ---
if [ -f "$OVERLAY_PATH" ]; then
    echo "[*] Injecting Overlay..."
    TARGET_OVERLAY_DIR="$MOUNT_POINT/system/product/overlay"
    sudo mkdir -p "$TARGET_OVERLAY_DIR"
    sudo cp "$OVERLAY_PATH" "$TARGET_OVERLAY_DIR/"
    sudo chmod 644 "$TARGET_OVERLAY_DIR/treble_overlay_xiaomi_alioth.apk"
    
    # Также кладем копию в /system/overlay на всякий случай
    sudo mkdir -p "$MOUNT_POINT/system/overlay"
    sudo cp "$OVERLAY_PATH" "$MOUNT_POINT/system/overlay/"
else
    echo "[!] WARNING: Overlay APK not found!"
fi

# --- B. ONEUI SPECIFIC FIXES (BUILD.PROP) ---
echo "[*] Applying OneUI 7 Fixes..."

# OneUI имеет вложенную структуру /system/system/
PROP_LOCATIONS=(
    "$MOUNT_POINT/system/build.prop"
    "$MOUNT_POINT/build.prop"
)

for PROP_FILE in "${PROP_LOCATIONS[@]}"; do
    if [ -f "$PROP_FILE" ]; then
        echo " -> Patching $PROP_FILE"
        
        # 1. Отключение RescueParty и защиты от крашей
        sudo bash -c "echo '' >> $PROP_FILE"
        sudo bash -c "echo '# ONEUI FIXES' >> $PROP_FILE"
        sudo bash -c "echo 'persist.sys.enable_rescue=0' >> $PROP_FILE"
        sudo bash -c "echo 'persist.sys.disable_rescue=1' >> $PROP_FILE"
        sudo bash -c "echo 'persist.sys.crash_rcu=0' >> $PROP_FILE"
        
        # 2. Отключение Samsung Security (Knox/Tima) - Главная причина ребутов
        sudo bash -c "echo 'ro.config.knox=0' >> $PROP_FILE"
        sudo bash -c "echo 'ro.config.tima=0' >> $PROP_FILE"
        sudo bash -c "echo 'ro.config.iccc_version=0' >> $PROP_FILE"
        sudo bash -c "echo 'ro.config.dmverity=false' >> $PROP_FILE"
        sudo bash -c "echo 'ro.security.vaultkeeper.feature=0' >> $PROP_FILE"
        sudo bash -c "echo 'sys.config.activelaunch=0' >> $PROP_FILE"
        
        # 3. Отладка
        sudo bash -c "echo 'persist.sys.usb.config=mtp,adb' >> $PROP_FILE"
        sudo bash -c "echo 'ro.adb.secure=0' >> $PROP_FILE"
        sudo bash -c "echo 'ro.debuggable=1' >> $PROP_FILE"
        
        # 4. Фикс графики
        sudo bash -c "echo 'debug.sf.latch_unsignaled=1' >> $PROP_FILE"
        sudo bash -c "echo 'debug.sf.disable_backpressure=1' >> $PROP_FILE"
    fi
done

# --- C. DEBLOAT (Удаление служб Samsung, вызывающих Kernel Panic) ---
echo "[*] Debloating broken Samsung services..."
SYS_ROOT="$MOUNT_POINT/system"

# Удаляем Knox и службы безопасности, которые не работают на Xiaomi
sudo rm -rf "$SYS_ROOT/app/Knox"*
sudo rm -rf "$SYS_ROOT/priv-app/Knox"*
sudo rm -rf "$SYS_ROOT/app/SecurityLogAgent"*
sudo rm -rf "$SYS_ROOT/app/SamsungPass"*
sudo rm -rf "$SYS_ROOT/priv-app/SamsungPass"*
sudo rm -rf "$SYS_ROOT/container" # Контейнеры Knox

# Удаление проверки шифрования (fstab)
echo "[*] Patching fstab (Disable Verify/Encrypt)..."
find "$MOUNT_POINT" -name "fstab*" | while read fstab; do
    echo " -> $fstab"
    sudo sed -i 's/,verify//g' "$fstab"
    sudo sed -i 's/,avb=[^,]*//g' "$fstab"
    sudo sed -i 's/forceencrypt/encryptable/g' "$fstab"
    sudo sed -i 's/fileencryption/encryptable/g' "$fstab"
done

# ==========================================
# 5. ФИНАЛИЗАЦИЯ
# ==========================================
echo "[+] Unmounting..."
sudo umount "$MOUNT_POINT"

echo "[+] Shrinking Image (to save space)..."
e2fsck -f -y system.img
resize2fs -M system.img

echo "[+] Zipping..."
mv system.img "OneUI7_Alioth_Port.img"
zip -r "$OUTPUT_DIR/${ROM_NAME}.zip" "OneUI7_Alioth_Port.img"

echo "=========================================="
echo "DONE! File is at $OUTPUT_DIR/${ROM_NAME}.zip"
echo "Don't forget to Format Data in TWRP!"
echo "=========================================="
