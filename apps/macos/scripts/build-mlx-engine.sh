#!/bin/zsh
# Build only the MLX engine, from a fresh source copy and frozen graph.
set -euo pipefail
repo_dir="${0:A:h:h}"
output="${AIM_MLX_ENGINE_BUILD_DIR:-$repo_dir/build/mlx-engine}"
if [[ -e "$output" || -L "$output" ]]; then
  echo 'MLX build requires a new output directory' >&2
  exit 1
fi
/usr/bin/python3 - "$repo_dir/scripts/release/prepare-runtime-inputs.py" "$output" <<'PY_OUTPUT'
import runpy, sys
runpy.run_path(sys.argv[1])['new_directory'](sys.argv[2])
PY_OUTPUT
mkdir -p "$output/home" "$output/tmp"
output="${output:A}"
# No inherited SwiftPM products, workspace state or caches.
/usr/bin/python3 - "$repo_dir/Vendor/AIMMLXEngine" "$output/source" <<'PY_COPY'
import shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2], ignore=shutil.ignore_patterns('.build', '.swiftpm', '.git'))
PY_COPY
cp "$output/source/Package.resolved" "$output/Package.resolved.before"
if [[ -n "${AIM_MLX_LICENSES_DIR:-}" ]]; then
  /usr/bin/python3 "$repo_dir/scripts/release/prepare-runtime-inputs.py" snapshot-mlx-notices \
    --source "$output/source" --notices "$AIM_MLX_LICENSES_DIR"
fi
cd "$output/source"
export TMPDIR="$output/tmp" CFFIXED_USER_HOME="$output/home"
export XDG_CACHE_HOME="$output/home/cache" XDG_CONFIG_HOME="$output/home/config"
# The Xcode launcher may not locate an installed cryptex component. Select its
# existing GPU executables locally; keep Swift/clang from the current Xcode.
/usr/bin/python3 "$repo_dir/scripts/release/prepare-runtime-inputs.py" compile-mlx --output "$output"

cmp "$output/Package.resolved.before" "$output/source/Package.resolved"
products="$output/dd/Build/Products/Release"
cp "$output/source/Package.resolved" "$products/Package.resolved"
if [[ -n "${AIM_MLX_LICENSES_DIR:-}" ]]; then
  cp -R "$output/source/Licenses" "$products/Licenses"
  /usr/bin/python3 "$repo_dir/scripts/verify-mlx-license-bundle.py" "$products"
fi
/usr/bin/shasum -a 256 "$products/aim-mlx-engine" "$products/Package.resolved" > "$output/product-sha256.txt"
echo "$products"
