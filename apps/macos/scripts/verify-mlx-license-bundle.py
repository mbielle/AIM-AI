#!/usr/bin/env python3
"""Fail packaging if the optional MLX engine lacks reviewed upstream license texts."""
import hashlib
import json
import pathlib
import sys


def verify(root):
    root = pathlib.Path(root).resolve(strict=True)
    resolved = root / "Package.resolved"
    license_root = root / "Licenses"
    manifest_path = license_root / "manifest.json"
    if not resolved.is_file() or resolved.is_symlink() or license_root.is_symlink() or not manifest_path.is_file() or manifest_path.is_symlink():
        raise ValueError("MLX packaging needs Package.resolved and Licenses/manifest.json; see docs/OPTIONAL_MLX_LICENSES.md")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("complete") is not True:
        raise ValueError("MLX license inventory must be explicitly reviewed as complete, including vendored C/C++ dependencies")
    pins = json.loads(resolved.read_text())["pins"]
    components = manifest["components"]
    identities = {item["identity"]: item for item in components}
    if len(identities) != len(components) or not components:
        raise ValueError("MLX license components must have unique identities")
    for pin in pins:
        item = identities.get(pin["identity"])
        if not item or item.get("revision") != pin["state"]["revision"]:
            raise ValueError("Missing license provenance for pinned dependency: " + pin["identity"])
    for item in components:
        files = item.get("licenses", [])
        if not files or not item.get("source") or not item.get("revision"):
            raise ValueError("Every MLX dependency needs source, revision and license texts")
        for record in files:
            path = license_root / record["path"]
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(license_root.resolve()):
                raise ValueError("Unsafe or missing MLX license file")
            contents = path.read_bytes()
            if len(contents) < 100 or hashlib.sha256(contents).hexdigest() != record["sha256"]:
                raise ValueError("Missing or changed MLX license text")
    return len(components)


if __name__ == "__main__":
    try:
        print("Verified MLX license components:", verify(sys.argv[1]))
    except (ValueError, KeyError, OSError, IndexError) as error:
        sys.exit("MLX license verification failed: " + str(error))
