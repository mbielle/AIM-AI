#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
if [[ "${1:-}" == "--help" || $# != 3 ]]; then
  echo "Usage: $0 <signed.dmg> <packaged-receipt.json> <notarytool-keychain-profile>"
  echo "Explicitly uploads to Apple, waits for acceptance, staples, and records verification."
  [[ "${1:-}" == "--help" ]] && exit 0
  exit 2
fi
dmg="${1:A}"
source_receipt="${2:A}"
profile="$3"
if [[ ! -f "$dmg" || "$dmg" != *.dmg || -z "$profile" || "$profile" == -* ]]; then
  echo "Require an existing .dmg and explicit keychain profile reference" >&2
  exit 2
fi
/usr/bin/python3 "$script_dir/distribution-tools.py" verify "$dmg" --receipt "$source_receipt"
work="$(mktemp -d "${dmg:h}/.notary-XXXXXXXX")"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json > "$work/submission.json"
/usr/bin/python3 - "$work/submission.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted' or not result.get('id'):
    raise SystemExit('Notarization not accepted; preserved submission output: ' + sys.argv[1])
PY
# Verify the exact submitted artifact before stapling changes its hash.
/usr/bin/python3 "$script_dir/distribution-tools.py" verify "$dmg" --receipt "$source_receipt"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg" 2> "$work/gatekeeper.txt"
/usr/bin/python3 "$script_dir/distribution-tools.py" receipt "$dmg" --release --stage notarized \
  --source-receipt "$source_receipt" --profile "$profile" --submission "$work/submission.json" \
  --gatekeeper "$work/gatekeeper.txt" --output "$dmg.notarized-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
echo "Notary outputs preserved: $work"
