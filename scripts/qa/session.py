#!/usr/bin/env python3
"""Record an existing owner authorization. This file grants no OS permissions."""
import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import sys


def validate(value, at=None):
    at = at or datetime.now(timezone.utc)
    start = datetime.fromisoformat(value["started_at"])
    expiry = datetime.fromisoformat(value["expires_at"])
    if start.tzinfo is None or expiry.tzinfo is None or not start <= at < expiry:
        raise ValueError("Créneau non commencé ou expiré")
    if not 0 < (expiry - start).total_seconds() <= 45 * 60:
        raise ValueError("Durée du créneau invalide")
    if not value.get("owner_authorization", "").strip():
        raise ValueError("Message propriétaire requis")
    if not re.fullmatch(r"com\.aimai\.macos\.qualification\.[0-9a-f]{32}", value["mac_bundle_id"]):
        raise ValueError("Identité Mac de qualification requise")
    if not re.fullmatch(r"com\.aimai\.ios\.(?:continuityqualification|qa\.[a-z0-9.]+)", value["ios_bundle_id"]):
        raise ValueError("Identité iPhone de qualification requise")
    if not value.get("device_id") or not set(value["allowed_actions"]) <= {"observe", "close", "install", "launch", "control"}:
        raise ValueError("Appareil ou actions invalides")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    begin = sub.add_parser("begin")
    for name in ["owner-authorization", "mac-bundle-id", "ios-bundle-id", "device-id", "output"]:
        begin.add_argument("--" + name, required=True)
    begin.add_argument("--minutes", type=int, default=45)
    begin.add_argument("--allow", choices=["observe", "close", "install", "launch", "control"], action="append", required=True)
    check = sub.add_parser("check")
    check.add_argument("path", type=Path)
    check.add_argument("--action", choices=["observe", "close", "install", "launch", "control"])
    args = parser.parse_args()
    try:
        if args.command == "begin":
            started = datetime.now(timezone.utc)
            value = dict(schema=1, started_at=started.isoformat(), expires_at=(started + timedelta(minutes=args.minutes)).isoformat(),
                owner_authorization=args.owner_authorization, mac_bundle_id=args.mac_bundle_id,
                ios_bundle_id=args.ios_bundle_id, device_id=args.device_id, allowed_actions=args.allow)
            validate(value, started)
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            import os
            fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(value, stream, indent=2, ensure_ascii=False)
                stream.write("\n")
            print("Créneau enregistré. Revalider avant chaque action physique.")
        else:
            value = validate(json.loads(args.path.read_text()))
            if args.action and args.action not in value["allowed_actions"]:
                raise ValueError("Action hors du créneau autorisé")
            print("Créneau actif jusqu'à", value["expires_at"])
        return 0
    except (ValueError, KeyError, OSError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
