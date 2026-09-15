#!/usr/bin/env python3
"""Sinh vector cho kenh E2EE v2 giua Grid desktop va Grid mobile.

Day la implementation THU BA: viet tu dac ta duoi day, khong transcribe tu
code Dart hay tu ban mobile. Mot cach doc sai dac ta se lo ra thanh bat dong
giua hai ben thay vi duoc ca hai cung ban phuoc.

Chay:
    python3 scripts/gen_e2ee_vectors.py            # ghi test/vectors/e2ee_handshake.txt
    python3 scripts/gen_e2ee_vectors.py --selftest # doi chieu voi vector Orca da publish

--- DAC TA ---

Transcript (big-endian toan bo):
    field(name, value) = u32(len(utf8(name))) || utf8(name)
                      || u32(len(value))      || value
    transcript = 24 field noi lien, dung thu tu duoi day.

    numberList(xs)  = u32(len(xs)) || u32(x) cho tung x
    stringList(xs)  = u32(len(xs)) || (u32(len(utf8(x))) || utf8(x)) cho tung x

Key schedule:
    transcriptHash = sha256(transcript)
    salt = sha256(utf8(saltLabel) || clientNonce || desktopNonce)
    info = utf8(sessionLabel) || transcriptHash
    okm  = HKDF-SHA256(ikm=sharedSecret, salt=salt, info=info, L=96)
    mobileToDesktopKey = okm[0:32]
    desktopToMobileKey = okm[32:64]
    sessionId          = okm[64:96]

    saltLabel va sessionLabel deu ket thuc bang mot byte NUL.

Frame layout (cai AEAD boc, khong phai cai AEAD tao ra):
    header(42) = sessionId(32) || direction(1) || kind(1) || u64(counter)
    nonce(24)  = sessionId[0:12] || 0x02 || direction || kind || 0x00 || u64(counter)
    direction: mobile->desktop = 0, desktop->mobile = 1
    kind:      text = 0, binary = 1
"""

import argparse
import hashlib
import hmac
import struct
import sys
from pathlib import Path

PROTOCOL_VERSION = 2
FRAMING = 2
PAYLOAD_KINDS = ["text", "binary"]
INITIATOR = "mobile"
RESPONDER = "desktop"

GRID_SUITE = {
    "protocol": "grid-mobile-e2ee",
    "transcript_domain": "grid-mobile-e2ee/v2/transcript",
    "salt_label": "grid-mobile-e2ee/v2/salt\0",
    "session_label": "grid-mobile-e2ee/v2/session\0",
}

# Vector da publish cua Orca (src/shared/mobile-e2ee-v2-fixtures.ts). Chi dung
# trong --selftest: neu script nay tai tao duoc dung bon con so do bang nhan
# Orca, thi cach doc dac ta o tren la dung — chu khong phai la doan.
ORCA_SUITE = {
    "protocol": "orca-mobile-e2ee",
    "transcript_domain": "orca-mobile-e2ee/v2/transcript",
    "salt_label": "orca-mobile-e2ee/v2/salt\0",
    "session_label": "orca-mobile-e2ee/v2/session\0",
}
ORCA_EXPECTED = {
    "transcript_length": 1347,
    "transcript_hash": "ca6385f8bbf64a223fdd59587bfb67e2373891ce9e6d85ab41df8b7a20a168e3",
    "mobile_to_desktop": "df17ff534df77fd3a30999f4e6200c8fcedefbb15d369301ca62c3cdfea9559a",
    "desktop_to_mobile": "71365fcf8212a6d63caf909ee28de3c8f689682ef298a374136055e0ab1cde4a",
    "session_id": "339ae1f2bdff63481857d2813c2f19dd1f5aa4824705d5e5daeb25dae7b9196e",
}


def u32(value: int) -> bytes:
    return struct.pack(">I", value)


def u64(value: int) -> bytes:
    return struct.pack(">Q", value)


def field(name: str, value: bytes) -> bytes:
    raw = name.encode("utf-8")
    return u32(len(raw)) + raw + u32(len(value)) + value


def number_list(values) -> bytes:
    return u32(len(values)) + b"".join(u32(v) for v in values)


def string_list(values) -> bytes:
    out = u32(len(values))
    for value in values:
        raw = value.encode("utf-8")
        out += u32(len(raw)) + raw
    return out


def context_fields(prefix: str, suite: dict, transport: str, relay_host_id: str) -> bytes:
    return (
        field(f"{prefix}.context.protocol", suite["protocol"].encode("utf-8"))
        + field(f"{prefix}.context.initiator", INITIATOR.encode("utf-8"))
        + field(f"{prefix}.context.responder", RESPONDER.encode("utf-8"))
        + field(f"{prefix}.context.transport", transport.encode("utf-8"))
        + field(f"{prefix}.context.relay-host-id", relay_host_id.encode("utf-8"))
    )


def encode_transcript(
    suite: dict,
    transport: str,
    relay_host_id: str,
    client_public_key: bytes,
    client_nonce: bytes,
    desktop_public_key: bytes,
    desktop_nonce: bytes,
) -> bytes:
    return (
        field("domain", suite["transcript_domain"].encode("utf-8"))
        + field("mobile-to-desktop.type", b"e2ee_hello")
        + field("mobile-to-desktop.version", u32(PROTOCOL_VERSION))
        + field("mobile-to-desktop.client-public-key", client_public_key)
        + field("mobile-to-desktop.client-nonce", client_nonce)
        + field("mobile-to-desktop.capabilities.framing", number_list([FRAMING]))
        + field(
            "mobile-to-desktop.capabilities.payload-kinds", string_list(PAYLOAD_KINDS)
        )
        + context_fields("mobile-to-desktop", suite, transport, relay_host_id)
        + field("desktop-to-mobile.type", b"e2ee_ready")
        + field("desktop-to-mobile.version", u32(PROTOCOL_VERSION))
        + field("desktop-to-mobile.desktop-public-key", desktop_public_key)
        + field("desktop-to-mobile.client-nonce-echo", client_nonce)
        + field("desktop-to-mobile.desktop-nonce", desktop_nonce)
        + field("desktop-to-mobile.selection.framing", u32(FRAMING))
        + field("desktop-to-mobile.selection.payload-kinds", string_list(PAYLOAD_KINDS))
        + context_fields("desktop-to-mobile", suite, transport, relay_host_id)
    )


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out = b""
    block = b""
    counter = 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


def derive(suite: dict, shared_secret: bytes, transcript: bytes,
           client_nonce: bytes, desktop_nonce: bytes) -> dict:
    transcript_hash = hashlib.sha256(transcript).digest()
    salt = hashlib.sha256(
        suite["salt_label"].encode("utf-8") + client_nonce + desktop_nonce
    ).digest()
    info = suite["session_label"].encode("utf-8") + transcript_hash
    okm = hkdf_sha256(shared_secret, salt, info, 96)
    return {
        "transcript_length": len(transcript),
        "transcript_hash": transcript_hash.hex(),
        "mobile_to_desktop": okm[0:32].hex(),
        "desktop_to_mobile": okm[32:64].hex(),
        "session_id": okm[64:96].hex(),
    }


def frame_header(session_id: bytes, direction: int, kind: int, counter: int) -> bytes:
    return session_id + bytes([direction, kind]) + u64(counter)


def frame_nonce(session_id: bytes, direction: int, kind: int, counter: int) -> bytes:
    return session_id[0:12] + bytes([FRAMING, direction, kind, 0]) + u64(counter)


def repeated(byte: int) -> bytes:
    return bytes([byte]) * 32


# Cung dung fixture voi Orca o case dau tien, de --selftest so duoc truc tiep.
HANDSHAKES = [
    {
        "name": "relay_repeated_bytes",
        "transport": "relay",
        "relay_host_id": "AbCdEf0123_-xyZ9",
        "client_public_key": repeated(0x01),
        "client_nonce": repeated(0x02),
        "desktop_public_key": repeated(0x03),
        "desktop_nonce": repeated(0x04),
        "shared_secret": repeated(0x05),
    },
    {
        "name": "direct_no_relay_host",
        "transport": "direct",
        "relay_host_id": "",
        "client_public_key": bytes(range(32)),
        "client_nonce": bytes(range(32, 64)),
        "desktop_public_key": bytes(range(64, 96)),
        "desktop_nonce": bytes(range(96, 128)),
        "shared_secret": bytes(range(128, 160)),
    },
]

FRAME_CASES = [
    ("text_m2d_zero", 0, 0, 0),
    ("text_d2m_one", 1, 0, 1),
    ("binary_m2d_large", 0, 1, 0x0102030405060708),
    ("binary_d2m_max_safe", 1, 1, 0x001FFFFFFFFFFFFF),
]


def run(suite: dict, handshake: dict) -> dict:
    transcript = encode_transcript(
        suite,
        handshake["transport"],
        handshake["relay_host_id"],
        handshake["client_public_key"],
        handshake["client_nonce"],
        handshake["desktop_public_key"],
        handshake["desktop_nonce"],
    )
    return derive(
        suite,
        handshake["shared_secret"],
        transcript,
        handshake["client_nonce"],
        handshake["desktop_nonce"],
    )


def selftest() -> int:
    got = run(ORCA_SUITE, HANDSHAKES[0])
    failures = [
        f"  {key}: mong {value!r}, ra {got[key]!r}"
        for key, value in ORCA_EXPECTED.items()
        if got[key] != value
    ]
    if failures:
        print("SELFTEST FAIL — cach doc dac ta khong khop Orca:")
        print("\n".join(failures))
        return 1
    print("SELFTEST OK — tai tao dung ca 5 gia tri Orca da publish.")
    return 0


def emit(path: Path) -> None:
    lines = [
        "# Vector kenh E2EE v2 giua Grid desktop va Grid mobile.",
        "# Nguon su that dung chung: hai ben phai ra dung nhung con so nay.",
        "#",
        "# Sinh boi scripts/gen_e2ee_vectors.py — implementation THU BA, viet tu",
        "# dac ta trong docstring cua script do, khong transcribe tu ben nao.",
        "# `python3 scripts/gen_e2ee_vectors.py --selftest` chay cung bo ham nay",
        "# tren nhan cua Orca va doi chieu voi vector Orca da publish; no phai PASS",
        "# truoc khi tin file nay. Do la bang chung cach doc dac ta la dung.",
        "#",
        "# Moi dong chua CA input LAN ket qua mong doi, cach nhau bang TAB.",
        "#",
        "# handshake <TAB> ten <TAB> transport <TAB> relay-host-id",
        "#           <TAB> client-pub <TAB> client-nonce",
        "#           <TAB> desktop-pub <TAB> desktop-nonce <TAB> shared-secret",
        "#           <TAB> transcript-len <TAB> transcript-sha256",
        "#           <TAB> m2d-key <TAB> d2m-key <TAB> session-id",
        "#",
        "# frame     <TAB> ten <TAB> session-id <TAB> direction <TAB> kind",
        "#           <TAB> counter <TAB> header <TAB> nonce",
        "#",
        "# direction: 0 = mobile->desktop, 1 = desktop->mobile.",
        "# kind:      0 = text, 1 = binary.",
        "# Moi cot byte deu la hex thuong, khong tien to.",
        "",
    ]
    for handshake in HANDSHAKES:
        result = run(GRID_SUITE, handshake)
        lines.append(
            "\t".join(
                [
                    "handshake",
                    handshake["name"],
                    handshake["transport"],
                    handshake["relay_host_id"] or "-",
                    handshake["client_public_key"].hex(),
                    handshake["client_nonce"].hex(),
                    handshake["desktop_public_key"].hex(),
                    handshake["desktop_nonce"].hex(),
                    handshake["shared_secret"].hex(),
                    str(result["transcript_length"]),
                    result["transcript_hash"],
                    result["mobile_to_desktop"],
                    result["desktop_to_mobile"],
                    result["session_id"],
                ]
            )
        )
    lines.append("")
    session_id = bytes.fromhex(run(GRID_SUITE, HANDSHAKES[0])["session_id"])
    for name, direction, kind, counter in FRAME_CASES:
        lines.append(
            "\t".join(
                [
                    "frame",
                    name,
                    session_id.hex(),
                    str(direction),
                    str(kind),
                    str(counter),
                    frame_header(session_id, direction, kind, counter).hex(),
                    frame_nonce(session_id, direction, kind, counter).hex(),
                ]
            )
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Da ghi {path} ({len(HANDSHAKES)} handshake, {len(FRAME_CASES)} frame).")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--out", default="test/vectors/e2ee_handshake.txt")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    # Khong bao gio ghi mot file vector khi cach doc dac ta chua duoc chung minh.
    if selftest() != 0:
        return 1
    emit(Path(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
