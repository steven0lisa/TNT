#!/bin/bash
# create-dmg.sh — 创建带背景图和拖拽引导的 DMG
# Usage: ./scripts/create-dmg.sh <app_path> <version> <output_path>
set -e

APP_PATH="${1:?Usage: create-dmg.sh <app_path> <version> <output_path>}"
VERSION="${2:?}"
OUTPUT_PATH="${3:?}"
VOLUME_NAME="TNT"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGING_DIR=$(mktemp -d)
DMG_TEMP="${STAGING_DIR}/tnt_temp.dmg"
MOUNT_POINT=""

cleanup() {
    [ -n "${MOUNT_POINT}" ] && hdiutil detach "${MOUNT_POINT}" -quiet 2>/dev/null || true
    rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

echo "[create-dmg] Version: ${VERSION}"

# 1. 生成背景图 (660x400, 浅色主题)
echo "[create-dmg] Generating background image..."
python3 << 'PYEOF'
import struct, zlib, os

WIDTH, HEIGHT = 660, 400

def make_png():
    pixels = []
    for y in range(HEIGHT):
        row = []
        for x in range(WIDTH):
            # Light background #f5f5f7
            r, g, b, a = 245, 245, 247, 255
            # Top accent bar (0-50px): blue gradient fading into white
            if y < 50:
                t = y / 50.0
                r = int(100 + (245 - 100) * t)
                g = int(150 + (245 - 150) * t)
                b = int(240 + (247 - 240) * t)
            # Bottom hint bar (360-400px): subtle gray
            elif y > 360:
                t = (y - 360) / 40.0
                r = int(245 - 10 * t)
                g = int(245 - 10 * t)
                b = int(247 - 8 * t)
            row.extend([r, g, b, a])
        pixels.append(bytes([0] + row))

    raw = b''.join(pixels)

    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 6, 0, 0, 0))  # 8bit RGBA
    idat = chunk(b'IDAT', zlib.compress(raw, 9))
    iend = chunk(b'IEND', b'')
    return sig + ihdr + idat + iend

bg_dir = os.environ.get('BG_DIR', '/tmp')
path = os.path.join(bg_dir, 'background.png')
with open(path, 'wb') as f:
    f.write(make_png())
print(f'Background saved: {path} ({os.path.getsize(path)} bytes)')
PYEOF

# 2. 创建目录结构
echo "[create-dmg] Creating staging directory..."
mkdir -p "${STAGING_DIR}/${VOLUME_NAME}/.background"
cp -R "${APP_PATH}" "${STAGING_DIR}/${VOLUME_NAME}/"
ln -s /Applications "${STAGING_DIR}/${VOLUME_NAME}/Applications"
BG_DIR="${STAGING_DIR}/${VOLUME_NAME}/.background" python3 << 'PYEOF'
import struct, zlib, os

WIDTH, HEIGHT = 660, 400

def make_png():
    pixels = []
    for y in range(HEIGHT):
        row = []
        for x in range(WIDTH):
            # Light background #f5f5f7
            r, g, b, a = 245, 245, 247, 255
            # Top accent bar (0-50px): blue gradient fading into white
            if y < 50:
                t = y / 50.0
                r = int(100 + (245 - 100) * t)
                g = int(150 + (245 - 150) * t)
                b = int(240 + (247 - 240) * t)
            # Bottom hint bar (360-400px): subtle gray
            elif y > 360:
                t = (y - 360) / 40.0
                r = int(245 - 10 * t)
                g = int(245 - 10 * t)
                b = int(247 - 8 * t)
            row.extend([r, g, b, a])
        pixels.append(bytes([0] + row))

    raw = b''.join(pixels)

    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 6, 0, 0, 0))
    idat = chunk(b'IDAT', zlib.compress(raw, 9))
    iend = chunk(b'IEND', b'')
    return sig + ihdr + idat + iend

bg_dir = os.environ['BG_DIR']
path = os.path.join(bg_dir, 'background.png')
with open(path, 'wb') as f:
    f.write(make_png())
PYEOF

echo "[create-dmg] Staging contents:"
ls -la "${STAGING_DIR}/${VOLUME_NAME}/"

# 3. 创建可写 DMG
echo "[create-dmg] Creating writable DMG..."
hdiutil create -volname "${VOLUME_NAME}" \
  -fs HFS+ -fsargs '-c c=64,a=16,e=16' \
  -size 400m "${DMG_TEMP}"

# 4. 挂载
MOUNT_POINT="/Volumes/${VOLUME_NAME}"
hdiutil attach "${DMG_TEMP}" -nobrowse -mountpoint "${MOUNT_POINT}"

# 5. 复制内容到 DMG
echo "[create-dmg] Copying files to DMG..."
cp -R "${STAGING_DIR}/${VOLUME_NAME}/.background" "${MOUNT_POINT}/"
cp -R "${STAGING_DIR}/${VOLUME_NAME}/TNT.app" "${MOUNT_POINT}/"
cp -R "${STAGING_DIR}/${VOLUME_NAME}/Applications" "${MOUNT_POINT}/"

# 6. 设置 Finder 窗口布局
echo "[create-dmg] Configuring Finder layout..."
osascript << APPLESCRIPT || echo "[create-dmg] Warning: Finder layout failed (non-fatal)"
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 760, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "TNT.app" of container window to {160, 220}
        set position of item "Applications" of container window to {500, 220}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# 7. 同步并卸载
echo "[create-dmg] Finalizing..."
sync
hdiutil detach "${MOUNT_POINT}" -quiet
MOUNT_POINT=""

# 8. 转换为压缩只读 DMG
echo "[create-dmg] Converting to compressed DMG..."
mkdir -p "$(dirname "${OUTPUT_PATH}")"
hdiutil convert "${DMG_TEMP}" -format UDZO \
  -imagekey zlib-level=9 \
  -o "${OUTPUT_PATH}"

# 9. Ad-hoc 签名
codesign --force --deep --sign - "${OUTPUT_PATH}"

echo "[create-dmg] Done: ${OUTPUT_PATH}"
ls -lh "${OUTPUT_PATH}"
