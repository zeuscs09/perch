#!/bin/bash
# ประกอบ Perch.app
#
#   ./Scripts/make-app.sh              บิลด์ release ไว้ที่ host/dist/Perch.app
#   ./Scripts/make-app.sh --install    บิลด์แล้วติดตั้งลง /Applications และเปิดให้เลย
#   ./Scripts/make-app.sh --debug      บิลด์ debug (ไว้ตอนพัฒนา)
#
# ทำไมต้องเป็น .app: TCC บน macOS 26 ไม่ยอมรับ Mach-O เปล่าแม้จะฝัง __info_plist ไว้แล้ว
# และคำขอสิทธิ์ Bluetooth จะถูกผูกกับ "responsible process" ซึ่งคือ Terminal ถ้ารันจากเชลล์
# ผลคือ SIGABRT (__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__) ไม่ใช่การปฏิเสธแบบสุภาพ
# ต้องเปิดผ่าน LaunchServices (`open`) หรือดับเบิลคลิกจาก Finder เท่านั้น
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(cd .. && pwd)"

CONFIG=release
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --debug) CONFIG=debug ;;
        *) echo "unknown option $arg" >&2; exit 1 ;;
    esac
done

# ไอคอนมาจาก docs/images/perch-logo.png ผ่าน make_icon.py (เติมขอบ + ทำ .icns)
if [ ! -f Resources/AppIcon.icns ]; then
    python3 "$REPO/tools/make_icon.py"
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/perch"
APP="dist/Perch.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/perch"
cp Sources/perch/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ลายเซ็น adhoc: พอสำหรับเครื่องที่บิลด์เอง แต่สิทธิ์ TCC ผูกกับ cdhash
# บิลด์ใหม่ = ตัวตนใหม่ = macOS ถามสิทธิ์ Bluetooth อีกรอบ
# การแจกให้เครื่องอื่นต้องใช้ Developer ID + notarization ซึ่งต้องมีบัญชีนักพัฒนา
codesign --force --deep --sign - --identifier com.perch.daemon "$APP" >/dev/null
echo "built $PWD/$APP"

if [ "$INSTALL" = "1" ]; then
    DEST="/Applications/Perch.app"
    # ชื่อเก่าก่อนโครงการเปลี่ยนมาเป็น Perch — ต้องถูก *ลบ* ไม่ใช่แค่ถูกทับ เพราะบันเดิล
    # ที่รันได้พร้อมกันสองตัวจะแย่ง socket เดียวกัน แล้วตัวที่แพ้เด้ง alert ทิ้ง
    LEGACY="/Applications/TamaClaude.app /Applications/tamaclaude.app"
    # ตัวเก่าอาจรันอยู่ ปิดก่อนไม่งั้นได้ไบนารีเก่าค้างในหน่วยความจำ และตัวใหม่จะจอง
    # socket ไม่ได้แล้วเด้ง alert ทิ้ง — ต้องปิดให้ตายจริงก่อน ไม่ใช่ส่งสัญญาณแล้วเดินต่อ
    #
    # จับที่ *ชื่อไบนารี* ทั้งเก่าและใหม่ ไม่ใช่ชื่อบันเดิล — รอบที่ข้ามชื่อคือรอบเดียวที่
    # ตัวที่กำลังรันอยู่ชื่อไม่เหมือนตัวที่กำลังจะติดตั้ง ถ้าไล่ฆ่าแต่ชื่อใหม่จะไม่โดนอะไรเลย
    RUNNING="\.app/Contents/MacOS/(perch|tamaclaude)"
    pkill -f "$RUNNING" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        pgrep -f "$RUNNING" >/dev/null || break
        sleep 1
    done
    # จำไว้ *ก่อน* ลบ — คำเตือนข้างล่างต้องขึ้นเฉพาะรอบที่ย้ายชื่อจริง คำเตือนที่ขึ้นทุกรอบ
    # ทั้งที่ไม่มีอะไรเปลี่ยนคือคำเตือนที่ผู้ใช้เลิกอ่านตั้งแต่ครั้งที่สอง
    #
    # ถามจากรายชื่อในโฟลเดอร์ ไม่ใช่ `[ -d ... ]` — APFS ปริยายไม่แยกตัวพิมพ์ใหญ่เล็ก
    # `TamaClaude.app` กับ `tamaclaude.app` จึงตอบว่า "มี" ให้กันและกันเสมอ
    RENAMED=0
    for old in $LEGACY; do
        if ls /Applications | grep -qxF "$(basename "$old")"; then RENAMED=1; fi
    done
    rm -rf "$DEST" $LEGACY
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "installed $DEST and launched it"
    echo "อนุญาต Bluetooth เมื่อระบบถาม แล้วเปิดเมนูจากไอคอนบนแถบเมนู"
    # hook กับ statusline เก็บ *พาธเต็ม* ของ binary ไว้ตอนกดติดตั้ง การเปลี่ยนชื่อบันเดิล
    # จึงทำให้พาธนั้นชี้ไปที่ไฟล์ที่ไม่มีแล้ว — เงียบ ไม่มี error ให้เห็น
    if [ "$RENAMED" = "1" ]; then
        echo ""
        echo "ลบแอปชื่อเก่าแล้ว — ยังเหลืออีกสองอย่างที่ยังชี้ไปที่พาธเดิม:"
        echo "  ./Scripts/make-app.sh ไม่ได้แก้ให้ ต้องสั่งเอง"
        echo "  $DEST/Contents/MacOS/perch --install-hooks"
        echo "  $DEST/Contents/MacOS/perch --install-statusline"
    fi
fi
