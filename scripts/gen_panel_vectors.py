# Sinh vector khung cho Grid Panel — implementation doc lap, viet tu dac ta
# (docs/panel-protocol.md §1), khong chep tu ban Dart hay bat ky ban device nao.
#
# Day la implementation THU BA. Ban Dart kiem chinh no bang bo vector nay, va bat
# ky firmware nao cam vao sau cung phai kiem bang dung file do — neu hai ban cung
# hieu sai mot cho thi no lo ra thanh bat dong, thay vi duoc ca hai chuc phuc.
#
#   python3 scripts/gen_panel_vectors.py
import pathlib

# GAN LIEN VOI SAN PHAM. Byte thu hai la 0x47 = 'G' (Grid); Harness dung 0x48 = 'H'. Xem
# panel_frame.h de biet tai sao. Hai san pham chung mot mach va mot USB id, nen bo vector nay
# KHONG duoc dung chung giua hai ben nua — moi ben sinh bo cua rieng minh tu magic cua minh.
MAGIC = b"\xA5\x47"
VER = 1

def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc

# Kiem chung ham CRC voi gia tri check cong bo cua CRC-16/CCITT-FALSE.
assert crc16_ccitt_false(b"123456789") == 0x29B1, "CRC sai bien the"

def frame(type_code: int, payload: bytes) -> bytes:
    body = bytes([VER, type_code]) + len(payload).to_bytes(2, "little") + payload
    return MAGIC + body + crc16_ccitt_false(body).to_bytes(2, "little")

JSON, PCM = 0x01, 0x02
cases = [
    ("json_empty_object", JSON, b"{}"),
    ("json_hello", JSON, b'{"t":"hello","proto":1}'),
    ("json_utf8", JSON, '{"t":"note","v":"nghe roi"}'.encode()),
    ("json_payload_holds_magic", JSON, b'{"t":"x","v":"\xa5\x47\xa5\x47"}'),
    ("pcm_zero_length", PCM, b""),
    ("pcm_eight_bytes", PCM, bytes([0x00, 0xFF, 0x7F, 0x80, 0x01, 0xFE, 0xA5, 0x47])),
    # 1280 byte = dung kich thuoc chunk PCM that (80ms @ 8kHz mono 16-bit).
    ("pcm_real_chunk", PCM, bytes((i * 7 + 13) & 0xFF for i in range(1280))),
    ("json_max_payload", JSON, b"z" * 8192),
]

lines = [
    "# Vector khung Grid Panel — nguon su that dung chung cho ca Dart lan C.",
    "# CHI cho Grid: magic A5 47. Harness dung A5 48 va co bo vector rieng — dung chung se sai.",
    "# Sinh boi scripts/gen_vectors.py (implementation thu ba, viet tu dac ta).",
    "# Dinh dang:  ten <TAB> type <TAB> payload-hex <TAB> frame-hex",
    "#",
    "# CRC-16/CCITT-FALSE check value cua \"123456789\" = 0x29B1 (da assert luc sinh).",
    "",
]
for name, t, payload in cases:
    lines.append(f"{name}\t{t}\t{payload.hex()}\t{frame(t, payload).hex()}")

# Tuong doi so voi chinh script, khong phai duong dan tuyet doi cua mot may.
out = pathlib.Path(__file__).resolve().parent.parent / "test" / "vectors" / "panel_frame.txt"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(lines) + "\n")
print("wrote", out)
for name, t, payload in cases:
    f = frame(t, payload)
    print(f"  {name:26} payload={len(payload):5}B frame={len(f):5}B  {f[:12].hex()}...")
