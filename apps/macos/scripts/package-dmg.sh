#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
if [[ "${1:-}" == "--help" || $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <signed.app> <build-receipt.json> [new-output.dmg]"
  echo "Packages an existing Developer ID bundle; no build, install, launch or upload."
  [[ "${1:-}" == "--help" ]] && exit 0
  exit 2
fi
app_dir="${1:A}"
source_receipt="${2:A}"
dmg="${3:-${app_dir:h}/AIM-AI-macOS-$(date -u +%Y%m%dT%H%M%SZ)-$$.dmg}"
dmg="${dmg:A}"
identity="${AIM_CODESIGN_IDENTITY:-}"
if [[ "$identity" != "Developer ID Application:"* || ! -d "$app_dir" || "$app_dir" != *.app || "$dmg" != *.dmg || -e "$dmg" ]]; then
  echo "Require Developer ID Application identity, existing .app, and a new .dmg path" >&2
  exit 2
fi
/usr/bin/python3 "$script_dir/distribution-tools.py" guard "$app_dir"
/usr/bin/python3 "$script_dir/distribution-tools.py" verify "$app_dir" --receipt "$source_receipt"
mkdir -p "${dmg:h}"
work="$(mktemp -d "${dmg:h}/.dmg-XXXXXXXX")"
mkdir "$work/root"
ditto "$app_dir" "$work/root/${app_dir:t}"
ln -s /Applications "$work/root/Applications"
hdiutil create -volname "AIM AI" -srcfolder "$work/root" -format UDZO "$work/distribution.dmg"
codesign --force --timestamp --sign "$identity" "$work/distribution.dmg"
# Check the bundle again: an input changed during copying must not be released.
/usr/bin/python3 "$script_dir/distribution-tools.py" verify "$app_dir" --receipt "$source_receipt"
/usr/bin/python3 "$script_dir/distribution-tools.py" verify "$work/root/${app_dir:t}" --receipt "$source_receipt"
# link is atomic and refuses an existing destination, unlike an overwriting mv.
ln "$work/distribution.dmg" "$dmg"
/usr/bin/python3 "$script_dir/distribution-tools.py" receipt "$dmg" --release --stage packaged \
  --source-receipt "$source_receipt" --output "$dmg.receipt.json"
rm -rf "$work"
echo "$dmg"
