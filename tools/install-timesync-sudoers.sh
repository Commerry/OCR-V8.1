#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Let the OCR program set this device's clock, and nothing else.
#
# The camera corrects its own time from the central server on every heartbeat
# (src/utils/timeSync.js). Changing the clock needs root, so this installs a
# sudoers rule scoped to exactly the commands involved - no general root access
# is granted, and a mistake in the program cannot turn into one.
#
#   sudo bash tools/install-timesync-sudoers.sh          # for the current user
#   sudo bash tools/install-timesync-sudoers.sh pi       # for a named user
# ---------------------------------------------------------------------------
set -eu

USER_NAME="${1:-${SUDO_USER:-$(id -un)}}"
FILE=/etc/sudoers.d/ocr-settime

if [ "$(id -u)" -ne 0 ]; then
    echo "ต้องรันด้วย sudo: sudo bash $0 $USER_NAME" >&2
    exit 1
fi

# find the real paths - they differ between Raspberry Pi OS versions
DATE_BIN=$(command -v date || echo /usr/bin/date)
TDC_BIN=$(command -v timedatectl || echo /usr/bin/timedatectl)
HWC_BIN=$(command -v hwclock || echo /sbin/hwclock)
FHW_BIN=$(command -v fake-hwclock || echo /usr/sbin/fake-hwclock)

TMP=$(mktemp)
cat > "$TMP" <<RULES
# Installed by OCR-V8.1 (tools/install-timesync-sudoers.sh)
# Lets the camera program keep its clock in step with the central server.
# These commands only - no shell, no package management, no file writes.
$USER_NAME ALL=(root) NOPASSWD: $DATE_BIN -u -s *
$USER_NAME ALL=(root) NOPASSWD: $TDC_BIN set-time *
$USER_NAME ALL=(root) NOPASSWD: $TDC_BIN set-timezone *
$USER_NAME ALL=(root) NOPASSWD: $TDC_BIN set-ntp *
$USER_NAME ALL=(root) NOPASSWD: $TDC_BIN show -p Timezone --value
$USER_NAME ALL=(root) NOPASSWD: $HWC_BIN -w
$USER_NAME ALL=(root) NOPASSWD: $FHW_BIN save
RULES

# never install a file that would break sudo for everyone
if ! visudo -cf "$TMP" >/dev/null; then
    echo "ไฟล์ sudoers ที่สร้างขึ้นไม่ผ่านการตรวจ - ไม่ได้ติดตั้ง" >&2
    rm -f "$TMP"
    exit 1
fi

install -m 0440 -o root -g root "$TMP" "$FILE"
rm -f "$TMP"
echo "ติดตั้ง $FILE ให้ผู้ใช้ $USER_NAME แล้ว"

# fake-hwclock keeps the time across a power cut on boards without an RTC
if [ ! -x "$FHW_BIN" ]; then
    echo "หมายเหตุ: ไม่มี fake-hwclock - ลงเพิ่มได้ด้วย apt-get install -y fake-hwclock"
fi

echo "ทดสอบ: sudo -n $TDC_BIN show -p Timezone --value"
sudo -u "$USER_NAME" sudo -n "$TDC_BIN" show -p Timezone --value 2>/dev/null \
    && echo "ใช้งานได้" \
    || echo "ยังใช้ไม่ได้ - ตรวจว่าผู้ใช้ $USER_NAME ถูกต้องหรือไม่"
