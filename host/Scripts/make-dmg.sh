#!/bin/bash
# ประกอบ Perch-<version>.dmg สำหรับแจกจ่าย
#
#   ./Scripts/make-dmg.sh                    บิลด์ .app ใหม่แล้วห่อเป็น dmg ไว้ที่ host/dist/
#   ./Scripts/make-dmg.sh --skip-build       ใช้ dist/Perch.app ที่มีอยู่แล้ว
#
# เซ็นด้วย Developer ID (ถ้ามีบัญชีนักพัฒนา) แล้วส่ง notarize:
#   SIGN_ID="Developer ID Application: ชื่อคุณ (TEAMID)" \
#   NOTARY_PROFILE=ชื่อโปรไฟล์ที่เก็บไว้ด้วย notarytool store-credentials \
#   ./Scripts/make-dmg.sh
#
# ไม่ตั้ง SIGN_ID = เซ็น adhoc เหมือน make-app.sh ซึ่งเปิดได้เฉพาะเครื่องที่บิลด์เอง
# เครื่องอื่นจะโดน Gatekeeper บล็อกเพราะ dmg ที่โหลดผ่านเน็ตติด quarantine
set -euo pipefail

cd "$(dirname "$0")/.."

SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        *) echo "unknown option $arg" >&2; exit 1 ;;
    esac
done

APP="dist/Perch.app"

if [ "$SKIP_BUILD" = "0" ]; then
    ./Scripts/make-app.sh
elif [ ! -d "$APP" ]; then
    echo "ไม่พบ $APP — รันโดยไม่ใส่ --skip-build ก่อน" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOLNAME="Perch $VERSION"
DMG="dist/Perch-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true' EXIT

# เซ็นแอปด้วย Developer ID ทับลายเซ็น adhoc ที่ make-app.sh ใส่ไว้
# ต้องมี --options runtime ไม่งั้น notarytool ปฏิเสธ (hardened runtime บังคับตั้งแต่ปี 2019)
if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGN_ID" --identifier com.perch.daemon "$APP"
    echo "signed $APP with $SIGN_ID"
fi

# หน้าต่างที่เด้งตอนเมานต์: แอปอยู่ซ้าย ลูกศรลาก /Applications อยู่ขวา
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
RW="$STAGE/../rw-$$.dmg"

# UDRW ก่อนเพราะต้องเมานต์เข้าไปจัดหน้าต่างด้วย Finder แล้วค่อยบีบเป็น UDZO อ่านอย่างเดียว
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -ov "$RW" >/dev/null

MOUNT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)"

osascript >/dev/null <<APPLESCRIPT || echo "จัดหน้าต่าง Finder ไม่สำเร็จ — dmg ยังใช้ได้ปกติ แค่ไอคอนไม่เข้าที่" >&2
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 150, 800, 550}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set position of item "Perch.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"

if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --sign "$SIGN_ID" "$DMG"
else
    codesign --force --sign - "$DMG"
fi

# notarize: Apple ตรวจแล้วประทับตั๋วลงบน dmg เอง (stapler) เครื่องปลายทางจึงเช็คได้ออฟไลน์
if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${SIGN_ID:-}" ]; then
        echo "notarize ต้องเซ็นด้วย Developer ID ก่อน — ตั้ง SIGN_ID ด้วย" >&2
        exit 1
    fi
    echo "ส่ง notarize (รอ Apple ตรวจ อาจใช้เวลาหลายนาที)..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "built $PWD/$DMG"
[ -z "${SIGN_ID:-}" ] && echo "หมายเหตุ: ลายเซ็น adhoc — เปิดได้เฉพาะเครื่องนี้ เครื่องอื่นต้องมี Developer ID + notarize"
exit 0
