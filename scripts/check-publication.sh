#!/bin/sh
# Maintainer gate for the exact staged source; does not create a remote or upload anything.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$repo_dir/scripts/audit-publication.py" --root "$repo_dir" --tracked
python3 "$repo_dir/scripts/audit-assets.py" --root "$repo_dir" --tracked --release
