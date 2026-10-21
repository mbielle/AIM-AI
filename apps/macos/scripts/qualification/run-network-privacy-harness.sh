#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
core_dir="${AIM_CORE_SOURCE_ROOT:-$repo_dir/../../packages/AIMCore}"
if [[ ! -f "$core_dir/Package.swift" || ! -d "$core_dir/Sources/AIMCore" ]]; then
  echo 'AIMCore source package is unavailable; set AIM_CORE_SOURCE_ROOT to the shared package' >&2
  exit 2
fi
run_dir="$(mktemp -d /private/tmp/aim-network-privacy-qualification.XXXXXXXX)"
namespace="com.aimai.macos.qualification.$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
[[ "$namespace" != *5af0* ]] || { echo 'Refusing reserved qualification namespace' >&2; exit 1; }
app_dir="$run_dir/NetworkPrivacyHarness.app"
mkdir -p "$app_dir/Contents/MacOS" "$run_dir/module-cache"
/usr/libexec/PlistBuddy -c 'Clear dict' "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $namespace" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AIMQualificationNamespace string $namespace" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string NetworkPrivacyHarness' "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$app_dir/Contents/Info.plist"
sources=(
 "$core_dir/Sources/AIMCore/Configuration/AIMInstallationContext.swift"
 "$core_dir/Sources/AIMCore/Networking/AIMNetworkPrivacyPolicy.swift"
 "$core_dir/Sources/AIMCore/Networking/AIMNetworkPrivacyTransaction.swift"
 "$core_dir/Sources/AIMCore/Networking/AIMNativeNetworkLifetime.swift"
)
shasum -a 256 "${sources[@]}" > "$run_dir/stock-sources-before.sha256"
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$run_dir/module-cache" \
 "${sources[@]}" "$repo_dir/scripts/qualification/NetworkPrivacyHarness.swift" \
 -framework Foundation -framework Network -o "$app_dir/Contents/MacOS/NetworkPrivacyHarness" \
 > "$run_dir/compile.log" 2>&1 || { cat "$run_dir/compile.log"; echo "RECEIPTS $run_dir"; exit 1; }
codesign --force --sign - --timestamp=none "$app_dir" > "$run_dir/sign.log" 2>&1
codesign --verify --deep --strict --verbose=2 "$app_dir" > "$run_dir/sign-verify.log" 2>&1
codesign -d --verbose=4 "$app_dir" > "$run_dir/sign-details.log" 2>&1
AIM_HARNESS_NAMESPACE="$namespace" "$app_dir/Contents/MacOS/NetworkPrivacyHarness" > "$run_dir/run.log" 2>&1 || { cat "$run_dir/run.log"; echo "RECEIPTS $run_dir"; exit 1; }
shasum -a 256 "${sources[@]}" > "$run_dir/stock-sources-after.sha256"
cmp "$run_dir/stock-sources-before.sha256" "$run_dir/stock-sources-after.sha256"
shasum -a 256 "$app_dir/Contents/MacOS/NetworkPrivacyHarness" "$app_dir/Contents/Info.plist" "$repo_dir/scripts/qualification/NetworkPrivacyHarness.swift" "$0" > "$run_dir/harness.sha256"
printf '%s\n' "$namespace" > "$run_dir/namespace.txt"
cat "$run_dir/run.log"
printf 'RECEIPTS %s\n' "$run_dir"
