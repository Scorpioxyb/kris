from __future__ import annotations

import hashlib
import hmac
import ipaddress
import os
import secrets
from datetime import UTC, datetime, timedelta
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from companion.config import CompanionConfig, ensure_private_directory


def ensure_secret(config: CompanionConfig) -> bytes:
    ensure_private_directory(config.state_dir)
    if config.secret_path.exists():
        return config.secret_path.read_bytes()
    secret = secrets.token_bytes(32)
    fd = os.open(config.secret_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(secret)
    return secret


def token_digest(secret: bytes, token: str) -> str:
    return hmac.new(secret, token.encode("utf-8"), hashlib.sha256).hexdigest()


def ensure_certificate(config: CompanionConfig) -> tuple[Path, Path]:
    ensure_private_directory(config.state_dir)
    if config.certificate_path.exists() and config.private_key_path.exists():
        return config.certificate_path, config.private_key_path

    key = ec.generate_private_key(ec.SECP256R1())
    subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Kris Mac")])
    now = datetime.now(UTC)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=825))
        .add_extension(
            x509.SubjectAlternativeName(
                [x509.DNSName("localhost"), x509.DNSName("kris-coach.local"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]
            ),
            critical=False,
        )
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    key_bytes = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    cert_bytes = certificate.public_bytes(serialization.Encoding.PEM)
    key_fd = os.open(config.private_key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(key_fd, "wb") as handle:
        handle.write(key_bytes)
    cert_fd = os.open(config.certificate_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(cert_fd, "wb") as handle:
        handle.write(cert_bytes)
    return config.certificate_path, config.private_key_path


def certificate_fingerprint(path: Path) -> str:
    cert = x509.load_pem_x509_certificate(path.read_bytes())
    return cert.fingerprint(hashes.SHA256()).hex().upper()


def constant_time_equal(left: str, right: str) -> bool:
    return hmac.compare_digest(left.encode("ascii"), right.encode("ascii"))
