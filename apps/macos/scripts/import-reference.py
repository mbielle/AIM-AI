#!/usr/bin/env python3
"""Import a pinned GitHub source snapshot into a new, auditable directory.

No source file is executed, no existing reference is overwritten, no Git token
is read, and imports do not claim any runtime or product qualification.
"""
import argparse
import collections
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import urllib.parse
import urllib.request
import zipfile

ALLOWED_HOSTS = {"api.github.com", "codeload.github.com", "github.com"}
MAX_ARCHIVE = 200 * 1024 * 1024
MAX_EXPANDED = 1024 * 1024 * 1024
MAX_FILES = 100000


class PinnedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlparse(newurl)
        if parsed.scheme != "https" or parsed.hostname not in ALLOWED_HOSTS or parsed.username or parsed.password:
            raise ValueError("Refused an untrusted source redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, destination=None, maximum=MAX_ARCHIVE):
    opener = urllib.request.build_opener(PinnedRedirect())
    request = urllib.request.Request(url, headers={"User-Agent": "AIM-reference-import/1", "Accept": "application/vnd.github+json"})
    with opener.open(request, timeout=45) as response:
        if response.status != 200:
            raise ValueError("Source endpoint did not return HTTP 200")
        count = 0
        digest = hashlib.sha256()
        data = bytearray() if destination is None else None
        handle = destination.open("xb") if destination else None
        try:
            while True:
                block = response.read(65536)
                if not block:
                    break
                count += len(block)
                if count > maximum:
                    raise ValueError("Source download exceeded its explicit size limit")
                digest.update(block)
                if handle:
                    handle.write(block)
                else:
                    data.extend(block)
        finally:
            if handle:
                handle.close()
        return {"final_url": response.url, "bytes": count, "sha256": digest.hexdigest()}, bytes(data) if data is not None else None


def version_hints(root):
    result = {}
    package = root / "package.json"
    if package.is_file() and not package.is_symlink() and package.stat().st_size < 1024 * 1024:
        value = json.loads(package.read_text())
        result["package.json"] = {key: value[key] for key in ("name", "version") if key in value}
    for filename in ("Cargo.toml", "pyproject.toml"):
        file = root / filename
        if file.is_file() and not file.is_symlink() and file.stat().st_size < 1024 * 1024:
            try:
                import tomllib
            except ModuleNotFoundError:
                try:
                    import tomli as tomllib
                except ModuleNotFoundError:
                    result[filename] = {"metadata_unavailable": "TOML parser absent; source preserved without inferred version"}
                    continue
            value = tomllib.loads(file.read_text())
            found = {}
            for path in (("package",), ("workspace", "package"), ("project",)):
                section = value
                for part in path:
                    section = section.get(part, {}) if isinstance(section, dict) else {}
                if isinstance(section, dict):
                    for key in ("name", "version"):
                        if isinstance(section.get(key), str):
                            found[".".join(path + (key,))] = section[key]
            result[filename] = found
    return result


def extract(archive, destination, preserve_link_metadata=False):
    languages = collections.Counter()
    links = []
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) > MAX_FILES or sum(entry.file_size for entry in entries) > MAX_EXPANDED:
            raise ValueError("Source archive exceeds file count or expanded size limits")
        roots = set()
        names = set()
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename or any(":" in part for part in path.parts):
                raise ValueError("Unsafe source archive path")
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                if not preserve_link_metadata or entry.file_size > 4096:
                    raise ValueError("Source archive contains a link; metadata-only opt-in required")
            elif mode and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_IFMT(mode) == 0):
                raise ValueError("Source archive contains a link or special file")
            if entry.filename in names:
                raise ValueError("Source archive contains a duplicate path")
            names.add(entry.filename)
            if path.parts:
                roots.add(path.parts[0])
        if len(roots) != 1:
            raise ValueError("Expected exactly one GitHub source root")
        root = next(iter(roots))
        for entry in entries:
            relative = PurePosixPath(entry.filename).parts[1:]
            if not relative:
                continue
            target = destination.joinpath(*relative)
            if stat.S_ISLNK(entry.external_attr >> 16):
                value = source.read(entry)
                links.append({"path": "/".join(relative), "target_text": value.decode("utf-8", errors="replace"), "sha256": hashlib.sha256(value).hexdigest(), "extracted": False})
                continue
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
                continue
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with source.open(entry) as original, target.open("xb") as output:
                shutil.copyfileobj(original, output, 65536)
            target.chmod(0o600)  # Imported reference code is never made executable.
            languages[target.suffix or "[no extension]"] += 1
        return {"archive_root": root, "files": sum(languages.values()), "extensions": dict(languages.most_common()), "unextracted_links": links}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, help="Official GitHub owner/repo or HTTPS repository URL")
    revision = parser.add_mutually_exclusive_group(required=True)
    revision.add_argument("--commit", help="Exact 40-character commit SHA (reproducible import)")
    revision.add_argument("--ref", help="Explicit branch/tag resolved to a commit before downloading")
    parser.add_argument("--destination", required=True, type=Path, help="Parent directory; every import creates a fresh child")
    parser.add_argument("--expected-archive-sha256", help="Optional independently pinned archive checksum")
    parser.add_argument("--baseline", type=Path, help="Existing reference directory, read-only version metadata comparison")
    parser.add_argument("--preserve-link-metadata", action="store_true", help="Record archive symlinks as untrusted metadata; never create or follow them")
    parser.add_argument("--reuse-download", type=Path, help="Reuse a preserved import folder after checking its repository, commit and exact archive SHA-256")
    args = parser.parse_args()
    repository = args.repository.removeprefix("https://github.com/").removesuffix("/").removesuffix(".git")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        parser.error("Repository must be an explicit GitHub owner/repo")
    if args.ref is not None and (not args.ref or len(args.ref) > 200):
        parser.error("Invalid branch/tag")
    if args.expected_archive_sha256 and not re.fullmatch(r"[0-9a-fA-F]{64}", args.expected_archive_sha256):
        parser.error("Invalid pinned archive SHA-256")
    commit = args.commit
    resolution = None
    if args.ref is not None:
        endpoint = "https://api.github.com/repos/" + repository + "/commits/" + urllib.parse.quote(args.ref, safe="")
        resolution, body = fetch(endpoint, maximum=1024 * 1024)
        commit = json.loads(body)["sha"]
    if not commit or not re.fullmatch(r"[0-9a-fA-F]{40}", commit):
        parser.error("Commit must resolve to an exact 40-character SHA")
    commit = commit.lower()
    if args.baseline and (not args.baseline.is_dir() or args.baseline.is_symlink()):
        parser.error("Baseline must be an existing directory")
    baseline = {"path": str(args.baseline.resolve()), "version_hints": version_hints(args.baseline)} if args.baseline else None
    args.destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    folder = args.destination / (repository.replace("/", "--") + "--" + commit[:12] + "--" + stamp)
    folder.mkdir(mode=0o700)  # exclusive, no replace/reset/cleanup of existing references
    archive = folder / "source.zip"
    report = {"schema_version": 1, "repository": "https://github.com/" + repository, "requested_ref": args.ref,
              "commit": commit, "imported_at": dt.datetime.now(dt.timezone.utc).isoformat(), "baseline": baseline,
              "qualified_runtime": False, "ref_resolution": resolution, "state": "downloading"}
    manifest = folder / "import-v1.json"
    try:
        if args.reuse_download:
            previous = args.reuse_download / "import-v1.json"
            original = args.reuse_download / "source.zip"
            if not previous.is_file() or previous.is_symlink() or previous.stat().st_size > 1024 * 1024 or not original.is_file() or original.is_symlink() or original.stat().st_size > MAX_ARCHIVE:
                raise ValueError("Invalid preserved download")
            receipt = json.loads(previous.read_text())
            if receipt.get("commit") != commit or receipt.get("repository") != "https://github.com/" + repository:
                raise ValueError("Preserved download does not match the requested source")
            digest = hashlib.sha256()
            with original.open("rb") as source, archive.open("xb") as output:
                for block in iter(lambda: source.read(65536), b""):
                    digest.update(block); output.write(block)
            expected = receipt.get("archive", {})
            if digest.hexdigest() != expected.get("sha256") or archive.stat().st_size != expected.get("bytes"):
                raise ValueError("Preserved download checksum mismatch")
            report["archive"] = expected
            report["reused_download"] = str(previous.resolve())
        else:
            report["archive"], _ = fetch("https://codeload.github.com/" + repository + "/zip/" + commit, destination=archive)
        if args.expected_archive_sha256 and report["archive"]["sha256"] != args.expected_archive_sha256.lower():
            raise ValueError("Archive did not match the independently pinned checksum")
        tree = folder / "source"
        tree.mkdir(mode=0o700)
        report["inventory"] = extract(archive, tree, preserve_link_metadata=args.preserve_link_metadata)
        report["version_hints"] = version_hints(tree)
        report["state"] = "imported-unqualified"
    except Exception as error:
        report["state"] = "failed-preserved"
        report["error"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        manifest.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        manifest.chmod(0o600)
    print(str(manifest.resolve()))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print("Reference import failed; staged evidence preserved: " + str(error), file=sys.stderr)
        raise SystemExit(1)
