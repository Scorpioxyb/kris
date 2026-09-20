from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class CompanionConfig:
    host: str = os.environ.get("KRIS_COMPANION_HOST", "0.0.0.0")
    port: int = int(os.environ.get("KRIS_COMPANION_PORT", "8843"))
    state_dir: Path = Path(os.environ.get("KRIS_COMPANION_STATE", ROOT / "companion" / ".state"))
    vault_dir: Path = Path(
        os.environ.get(
            "KRIS_VAULT_DATA",
            Path.home() / "Documents" / "Obsidian Vault" / "Kris 健身数据",
        )
    )
    refresh_script: Path = Path(os.environ.get("KRIS_REFRESH_SCRIPT", ROOT / "tools" / "refresh_kris.py"))
    service_name: str = os.environ.get("KRIS_COMPANION_NAME", "Kris Mac")

    @property
    def database_path(self) -> Path:
        return self.state_dir / "companion.sqlite3"

    @property
    def certificate_path(self) -> Path:
        return self.state_dir / "server.crt"

    @property
    def private_key_path(self) -> Path:
        return self.state_dir / "server.key"

    @property
    def secret_path(self) -> Path:
        return self.state_dir / "secret.key"


def ensure_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
