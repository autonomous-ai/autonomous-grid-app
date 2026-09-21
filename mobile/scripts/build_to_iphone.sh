#!/usr/bin/env bash
#
# Build Grid mobile bản Release rồi cài THẲNG lên iPhone — một phát.
#
#   mobile/scripts/build_to_iphone.sh [device] [cờ...]
#     device : tên/UDID iPhone (mặc định: tự dò máy đang cắm)
#
#   Cờ:
#     --no-launch  Không tự mở app sau khi cài
#     --clean      `flutter clean` trước khi build (chậm hơn; dùng khi build lỗi lạ)
#     -h|--help    In hướng dẫn
#
#   Ghi đè bằng biến môi trường: DEVICE, BUNDLE_ID
#
# CHỮ KÝ: app ký kiểu Development (CODE_SIGN_STYLE = Automatic, team
# 2WTM2C3J46). Script KHÔNG đoán hạn — nó đọc thẳng embedded.mobileprovision
# rồi in hạn thật sau khi cài. Hết hạn thì chạy lại script này là xong.
#
# Đo ngày 2026-09-21: team 2WTM2C3J46 cho profile sống **~7 ngày** (tài khoản
# dev miễn phí), nên app chết sau một tuần. Cùng hôm đó, 4 app trong
# ~/WorkPlace/GroupMe ký bằng team 54DJVWMJCC lại được **~364 ngày**. Muốn Grid
# mobile sống cả năm thì đổi DEVELOPMENT_TEAM sang tài khoản trả phí đó trong
# ios/Runner.xcodeproj — đây là việc của chữ ký, không phải của script này.
# (Header script me-phim ghi ngược lại: bảo dùng 2WTM2C3J46 để KHỎI hết hạn.
#  Số đo nói khác. Đo lại trước khi tin dòng nào trong hai dòng đó.)
#
# Grid mobile chỉ là điều khiển từ xa cho bản Grid chạy trên máy tính: cài xong
# vẫn phải ghép đôi với desktop thì mới có gì để xem.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
APP_PATH="$APP_DIR/build/ios/iphoneos/Runner.app"

# Phải khớp PRODUCT_BUNDLE_IDENTIFIER trong ios/Runner.xcodeproj/project.pbxproj
BUNDLE_ID="${BUNDLE_ID:-ai.autonomous.gridMobile}"

# shellcheck source=lib/detect_iphone.sh
source "$SCRIPT_DIR/lib/detect_iphone.sh"

# In khối chú thích đầu file, từ dòng 3 tới dòng không-phải-comment đầu tiên.
# Không đếm số dòng: sửa header xong là help tự đúng, khỏi lệch.
usage() { awk 'NR>=3 && /^#/ { sub(/^# ?/, ""); print; next } NR>=3 { exit }' "${BASH_SOURCE[0]}"; }

# --- Đọc tham số ---
DEVICE_ARG=""
DO_LAUNCH=1
DO_CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --no-launch) DO_LAUNCH=0 ;;
    --clean)     DO_CLEAN=1 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "❌ Cờ không hiểu: $arg" >&2; usage >&2; exit 1 ;;
    *)           DEVICE_ARG="$arg" ;;
  esac
done

# --- Điều kiện cần ---
# flutter nằm ở ~/WorkPlace/Flutter/flutter/bin và vào PATH qua ~/.zprofile, nên
# shell đăng nhập thấy nó. Cố ý KHÔNG ghi cứng đường dẫn ở đây: máy khác chỗ
# khác, và một đường dẫn chép sẵn sẽ âm thầm trỏ vào bản Flutter cũ.
command -v flutter >/dev/null 2>&1 || {
  echo "❌ Không thấy 'flutter' trong PATH." >&2
  echo "   Shell không-đăng-nhập (cron, IDE, agent) không đọc ~/.zprofile —" >&2
  echo "   thêm thư mục bin của Flutter vào PATH rồi chạy lại." >&2
  exit 1
}
command -v xcrun >/dev/null 2>&1 || { echo "❌ Không thấy 'xcrun' (cần Xcode)." >&2; exit 1; }
[[ -d "$APP_DIR/ios" ]] || { echo "❌ Không thấy thư mục ios/: $APP_DIR/ios" >&2; exit 1; }

# --- Dò máy ---
DEVICE="${DEVICE_ARG:-${DEVICE:-$(detect_iphone || true)}}"
if [[ -z "$DEVICE" ]]; then
  echo "❌ Không tìm thấy iPhone. Cắm máy (đã mở khoá + tin tưởng) rồi thử lại," >&2
  echo "   hoặc truyền UDID: $0 <udid>" >&2
  exit 1
fi
echo "📱 iPhone: $DEVICE"

# --- Build ---
cd "$APP_DIR"
if (( DO_CLEAN )); then
  echo "🧹 flutter clean…"
  flutter clean >/dev/null
fi
echo "🔨 flutter build ios --release … (lần đầu lâu, sau đó nhanh dần)"
if ! flutter build ios --release; then
  echo "❌ Build thất bại. Thử lại với: $0 --clean" >&2
  exit 1
fi
[[ -d "$APP_PATH" ]] || { echo "❌ Build xong nhưng không thấy: $APP_PATH" >&2; exit 1; }

# --- Hạn chữ ký (đọc từ gói vừa build, không đoán) ---
print_expiry() {
  local profile="$APP_PATH/embedded.mobileprovision" exp_raw exp_epoch now_epoch days
  [[ -f "$profile" ]] || return 0
  exp_raw="$(security cms -D -i "$profile" 2>/dev/null \
    | plutil -extract ExpirationDate raw - 2>/dev/null || true)"
  [[ -n "$exp_raw" ]] || return 0
  exp_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$exp_raw" +%s 2>/dev/null || true)"
  [[ -n "$exp_epoch" ]] || { echo "🔑 Hết hạn chữ ký: $exp_raw"; return 0; }
  now_epoch="$(date +%s)"
  days=$(( (exp_epoch - now_epoch) / 86400 ))
  echo "🔑 Chữ ký hết hạn: $exp_raw  (còn ~${days} ngày)"
  (( days <= 2 )) && echo "   ⚠️  Sắp hết hạn — cứ chạy lại script này để gia hạn."
  return 0
}

# --- Cài lên máy ---
echo "📦 Cài lên iPhone…"
INSTALL_LOG="$(mktemp)"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP_PATH" >"$INSTALL_LOG" 2>&1; then
  # In LÝ DO THẬT máy báo về, đừng đoán bệnh: nuốt stderr rồi tự suy
  # "chưa mở khoá / chưa tin tưởng" là cách tốn hàng giờ đi mò cáp.
  echo "❌ Cài thất bại. Máy báo về:" >&2
  grep -iE 'RecoverySuggestion|FailureReason|maximum number|cannot be installed' "$INSTALL_LOG" \
    | sed 's/^ *//; s/^/   /' | head -3 >&2
  case "$(cat "$INSTALL_LOG")" in
    *"maximum number of installed apps"*)
      echo "   → Tài khoản dev MIỄN PHÍ chỉ cho 3 app trên một máy." >&2
      echo "     Xoá bớt một app dev trên iPhone rồi chạy lại." >&2 ;;
    *"provisioning profile cannot be installed"*)
      echo "   → iPhone chưa nằm trong provisioning profile. Đăng ký nó bằng:" >&2
      echo "     cd ios && xcodebuild -workspace Runner.xcworkspace -scheme Runner \\" >&2
      echo "       -destination 'id=$DEVICE' -allowProvisioningDeviceRegistration build" >&2 ;;
    *"not paired"*|*"locked"*)
      echo "   → Mở khoá màn hình rồi bấm Tin cậy máy tính này." >&2 ;;
    *"application-identifier"*)
      # Gặp thật ngày 2026-09-21 khi đổi DEVELOPMENT_TEAM: iOS coi app đổi
      # team là app KHÁC nên từ chối cài đè, dù bundle id y hệt. Gỡ rồi cài
      # lại là hết — và đó là cách DUY NHẤT, không có đường nâng cấp tại chỗ.
      echo "   → Đổi team ký thì phải gỡ app cũ trước (iOS không cho cài đè):" >&2
      echo "     xcrun devicectl device uninstall app --device $DEVICE $BUNDLE_ID" >&2
      echo "     Gỡ là mất dữ liệu trong app + phải ghép đôi lại với desktop." >&2 ;;
  esac
  echo "   (log đầy đủ: $INSTALL_LOG)" >&2
  exit 1
fi
rm -f "$INSTALL_LOG"
print_expiry

# --- Mở app ---
if (( DO_LAUNCH )); then
  echo "🚀 Mở app…"
  if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "   (không tự mở được — máy đang khoá, hoặc profile dev chưa được tin tưởng:"
    echo "    Cài đặt → Cài đặt chung → VPN & Quản lý thiết bị → Tin cậy, rồi bấm icon app)"
  fi
fi

echo
echo "✅ Xong: đã build + cài Grid mobile lên iPhone."
echo "   Ghép đôi với Grid trên máy tính thì app mới có gì để hiện."
