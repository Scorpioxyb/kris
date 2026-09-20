from __future__ import annotations

import argparse
import os
from datetime import timedelta

from .auth import HMACDevelopmentSessionTokens


def main() -> int:
    parser = argparse.ArgumentParser(description="Issue a local development Kris device session token.")
    parser.add_argument("subject", help="Opaque development device subject; do not use an email or health identifier.")
    parser.add_argument("--minutes", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.minutes <= 1_440:
        parser.error("--minutes must be between 1 and 1440")
    subject = args.subject.strip()
    if not subject or len(subject) > 128:
        parser.error("subject must contain 1 to 128 characters")
    secret = os.environ.get("KRIS_AI_GATEWAY_SESSION_SECRET", "").encode("utf-8")
    if len(secret) < 32:
        parser.error("KRIS_AI_GATEWAY_SESSION_SECRET must contain at least 32 UTF-8 bytes")
    token = HMACDevelopmentSessionTokens(secret).issue(
        subject, lifetime=timedelta(minutes=args.minutes),
    )
    # The token is only emitted on explicit invocation, never during server startup.
    print(token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
