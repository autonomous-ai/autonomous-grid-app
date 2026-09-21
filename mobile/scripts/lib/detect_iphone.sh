#!/usr/bin/env bash
#
# Hàm dùng chung: dò iPhone (iOS) đang kết nối qua `devicectl` của Xcode 15+.
# In UDID ra stdout, rỗng nếu không thấy. Ưu tiên máy đang "connected";
# nếu không có thì lấy máy iOS đầu tiên đã ghép đôi.
#
# Dùng: source "<...>/lib/detect_iphone.sh"; DEVICE="$(detect_iphone || true)"
#
# Cố ý KHÔNG siết "chỉ chạy khi tunnelState=connected": devicectl hay báo
# disconnected trong khi tunnel vẫn dựng được lúc cài. Lấy máy đã ghép đôi làm
# phương án dự phòng thì đúng hơn — giống hệt bản trong ~/WorkPlace/GroupMe,
# chép sang chứ không tham chiếu, để repo này tự đứng được một mình.

detect_iphone() {
  local tmp
  tmp="$(mktemp)"
  if ! xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  python3 - "$tmp" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
devices = data.get("result", {}).get("devices", [])
fallback = None
for dev in devices:
    if dev.get("hardwareProperties", {}).get("platform") != "iOS":
        continue
    ident = dev.get("identifier") or dev.get("hardwareProperties", {}).get("udid", "")
    if dev.get("connectionProperties", {}).get("tunnelState") == "connected":
        print(ident)
        break
    fallback = fallback or ident
else:
    if fallback:
        print(fallback)
PY
  rm -f "$tmp"
}
