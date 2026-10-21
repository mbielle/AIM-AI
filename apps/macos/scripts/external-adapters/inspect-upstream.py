#!/usr/bin/env python3
"""Inspect pinned local sources; never import, install or execute an upstream engine.

A matching snapshot is evidence for the documented blocker, not adapter readiness.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys


MAX_SOURCE_BYTES = 16 * 1024 * 1024


def read_regular(root, relative):
    relative = Path(relative)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Source path escapes inspection root")
    path = root
    for component in relative.parts:
        path = path / component
        if path.is_symlink():
            raise ValueError("Symlink source is not accepted: " + str(relative))
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_SOURCE_BYTES:
            raise ValueError("Source must be a bounded regular file: " + str(relative))
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            contents = stream.read(MAX_SOURCE_BYTES + 1)
        if len(contents) > MAX_SOURCE_BYTES:
            raise ValueError("Source exceeded inspection limit: " + str(relative))
        return contents
    finally:
        os.close(descriptor)


def inspect(root, spec):
    base = root / spec["directory"]
    files = []
    for entry in spec["sources"]:
        result = {"path": entry["path"], "expectedSHA256": entry["sha256"]}
        try:
            contents = read_regular(root, Path(spec["directory"]) / entry["path"])
            result["actualSHA256"] = hashlib.sha256(contents).hexdigest()
            result["matchesPin"] = result["actualSHA256"] == entry["sha256"]
            line_count = len(contents.decode("utf-8").splitlines())
            result["evidence"] = entry["evidence"]
            result["evidenceRangesPresent"] = all(
                1 <= evidence["lineStart"] <= evidence["lineEnd"] <= line_count
                for evidence in entry["evidence"]
            )
        except (OSError, UnicodeError, ValueError) as error:
            result["matchesPin"] = False
            result["error"] = str(error)
        files.append(result)

    declared_version = None
    try:
        version_text = read_regular(root, Path(spec["directory"]) / spec["versionFile"]).decode("utf-8")
        if spec["identity"] == "openclaw":
            declared_version = json.loads(version_text).get("version")
        else:
            match = re.search(r'^version\s*=\s*"([^"]+)"\s*$', version_text, re.MULTILINE)
            declared_version = match.group(1) if match else None
    except (OSError, UnicodeError, ValueError):
        pass

    matches = declared_version == spec["declaredVersion"] and all(
        source["matchesPin"] and source.get("evidenceRangesPresent", False) for source in files
    )
    return {
        "identity": spec["identity"],
        "root": str(base),
        "declaredVersion": declared_version,
        "expectedDeclaredVersion": spec["declaredVersion"],
        "releaseOrCommitVerified": False,
        "snapshotMatches": matches,
        "adapterStatus": "blocked" if matches else "unreviewed-source",
        "qualified": False,
        "blockers": spec["blockers"],
        "sources": files,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="Local Agents exemple directory")
    parser.add_argument("--engine", choices=("hermes", "openclaw", "all"), default="all")
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[2] / "adapters" / "upstream-source-audit-v1.json")
    args = parser.parse_args()
    try:
        manifest = json.loads(read_regular(args.manifest.parent, args.manifest.name))
        if manifest.get("schemaVersion") != 1:
            raise ValueError("Unsupported audit manifest version")
        root = args.root.absolute()
        selected = [spec for spec in manifest["engines"] if args.engine in ("all", spec["identity"])]
        if not selected:
            raise ValueError("No matching engine in audit manifest")
        report = {
            "schemaVersion": 1,
            "inspectedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "mode": "offline-source-inspection",
            "executedUpstream": False,
            "modelCalls": 0,
            "engines": [inspect(root, spec) for spec in selected],
        }
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0 if all(engine["snapshotMatches"] for engine in report["engines"]) else 2
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("Inspection refused: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
