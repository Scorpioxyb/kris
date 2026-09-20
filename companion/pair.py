from __future__ import annotations

import argparse
import ipaddress
import re
import socket
import subprocess
from pathlib import Path
from urllib.parse import urlencode

from companion.config import CompanionConfig
from companion.security import certificate_fingerprint, ensure_certificate, ensure_secret
from companion.store import CompanionStore


def _is_pairable_ipv4(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value.strip())
    except ValueError:
        return False
    benchmark_network = ipaddress.ip_network("198.18.0.0/15")
    return (
        address.version == 4
        and not address.is_loopback
        and not address.is_link_local
        and not address.is_multicast
        and not address.is_unspecified
        and address not in benchmark_network
    )


def _interface_ipv4(interface: str) -> str | None:
    result = subprocess.run(
        ["/usr/sbin/ipconfig", "getifaddr", interface],
        capture_output=True,
        text=True,
        check=False,
    )
    candidate = result.stdout.strip()
    return candidate if result.returncode == 0 and _is_pairable_ipv4(candidate) else None


def local_ip() -> str:
    route = subprocess.run(
        ["/sbin/route", "-n", "get", "default"],
        capture_output=True,
        text=True,
        check=False,
    )
    match = re.search(r"^\s*interface:\s*(\S+)", route.stdout, flags=re.MULTILINE)
    interfaces = [match.group(1)] if match else []
    interfaces.extend(interface for interface in ("en0", "en1", "en2") if interface not in interfaces)
    for interface in interfaces:
        if candidate := _interface_ipv4(interface):
            return candidate

    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        candidate = str(probe.getsockname()[0])
        return candidate if _is_pairable_ipv4(candidate) else "127.0.0.1"
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a ten-minute Kris pairing QR")
    parser.add_argument("--host", default=None, help="LAN host/IP embedded in the QR")
    parser.add_argument("--output", type=Path, default=Path("companion/.state/pairing-qr.png"))
    args = parser.parse_args()
    config = CompanionConfig()
    certificate, _ = ensure_certificate(config)
    store = CompanionStore(config.database_path, ensure_secret(config))
    token = store.create_pairing_token()
    query = urlencode(
        {
            "host": args.host or local_ip(),
            "port": config.port,
            "fingerprint": certificate_fingerprint(certificate),
            "token": token,
        }
    )
    payload = f"kriscoach://pair?{query}"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    renderer = Path(__file__).with_name("render_qr.swift")
    result = subprocess.run(["/usr/bin/xcrun", "swift", str(renderer), payload, str(args.output)], check=False)
    print(payload)
    if result.returncode == 0:
        print(f"QR: {args.output.resolve()}")
    else:
        print("QR rendering failed; the pairing URI above can be pasted into the app.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
