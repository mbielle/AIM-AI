#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
configuration="${1:-debug}"
qualification=false
explicit_scratch=""
if [[ "${2:-}" == "--qualification" && "$configuration" == "debug" && $# -eq 2 ]]; then
  qualification=true
elif [[ "$configuration" == "release" && "${2:-}" == "--swift-scratch" && $# -eq 3 ]]; then
  explicit_scratch="$3"
elif (( $# > 1 )); then
  echo "Only debug --qualification or release --swift-scratch <fresh-path> accepts extra arguments" >&2
  exit 2
fi
if [[ "$configuration" == "--help" ]]; then
  echo "Usage: $0 [debug|release] [--qualification for debug | --swift-scratch <fresh-path> for release] (does not launch/install the app)"
  exit 0
fi
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  echo "Usage: $0 [debug|release]" >&2
  exit 2
fi

# Optional public client configuration for an isolated test app. Never copy
# credentials or preference databases from an existing installation.
if [[ -n "${AIM_PUBLIC_CONFIG_PLIST:-}" ]]; then
  if [[ "$qualification" != true || ! -f "$AIM_PUBLIC_CONFIG_PLIST" || -n "${AIM_SUPABASE_URL:-}" || -n "${AIM_SUPABASE_PUBLIC_KEY:-}" ]]; then
    echo "AIM_PUBLIC_CONFIG_PLIST requires qualification and no conflicting Supabase env configuration" >&2
    exit 2
  fi
  AIM_SUPABASE_URL="$(/usr/bin/plutil -extract AIMSupabaseURL raw "$AIM_PUBLIC_CONFIG_PLIST")"
  AIM_SUPABASE_PUBLIC_KEY="$(/usr/bin/plutil -extract AIMSupabasePublicKey raw "$AIM_PUBLIC_CONFIG_PLIST")"
fi
supabase_configured=false
if [[ -n "${AIM_SUPABASE_URL:-}" || -n "${AIM_SUPABASE_PUBLIC_KEY:-}" ]]; then
  AIM_SUPABASE_URL="${AIM_SUPABASE_URL:-}" AIM_SUPABASE_PUBLIC_KEY="${AIM_SUPABASE_PUBLIC_KEY:-}" \
    /usr/bin/python3 "$script_dir/validate-client-config.py"
  supabase_configured=true
fi

identity="${AIM_CODESIGN_IDENTITY:--}"
if [[ "$configuration" == "release" && "$identity" != "Developer ID Application:"* ]]; then
  echo "Release requires AIM_CODESIGN_IDENTITY naming a Developer ID Application identity" >&2
  exit 2
fi
sign_timestamp=(--timestamp)
if [[ "$identity" == "-" ]]; then sign_timestamp=(--timestamp=none); fi
if [[ "$qualification" == true && "${AIM_QUALIFICATION_NSXPC:-0}" == "1" ]]; then
  echo "Legacy signed-XPC fixtures are separate from an isolated qualification installation" >&2
  exit 2
fi
qualification_namespace=""
swift_scratch="$repo_dir/.build"
guard_flags=(--all-aim)
if [[ -n "$explicit_scratch" ]]; then
  /usr/bin/python3 - "$repo_dir" "$explicit_scratch" <<'SCRATCH_PREFLIGHT'
import pathlib, sys
root, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
build = root / 'build'
if (not target.is_absolute() or target.absolute().parent != build or target.suffix == '.app'
        or target.exists() or target.is_symlink() or build.is_symlink()
        or (build.exists() and not build.is_dir())):
    raise SystemExit('Fresh absolute Swift scratch directly inside build/ required; existing paths and symlinks refused')
SCRATCH_PREFLIGHT
  swift_scratch="$explicit_scratch"
fi
if [[ "$qualification" == true ]]; then
  qualification_id="$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  qualification_namespace="com.aimai.macos.qualification.$qualification_id"
  swift_scratch="$repo_dir/build/.qualification-$qualification_id/.build"
  app_dir="${AIM_APP_OUTPUT:-$repo_dir/build/AIM Continuity Test $qualification_id.app}"
  guard_flags=()
else
  app_dir="${AIM_APP_OUTPUT:-$repo_dir/build/AIM AI.app}"
fi
app_dir="${app_dir:A}"
if [[ "$app_dir" != "$repo_dir/build/"*.app || "${app_dir:h}" != "$repo_dir/build" ]]; then
  echo "AIM_APP_OUTPUT must name an .app inside this repository's build directory" >&2
  exit 2
fi
if [[ "$qualification" == true && ( -e "$app_dir" || -L "$app_dir" || -e "$swift_scratch" ) ]]; then
  echo "Qualification requires a new destination and a fresh Swift scratch directory" >&2
  exit 2
fi
# A bundle build can invalidate an executable used by the active UI or helper.
# Refuse before Swift touches its products, then check again before replacement.
/usr/bin/python3 "$script_dir/distribution-tools.py" guard "${guard_flags[@]}" "$app_dir" "$swift_scratch"
mkdir -p "$repo_dir/build"
if [[ -n "$explicit_scratch" ]]; then
  # mkdir is exclusive: never adopt a scratch path created after preflight.
  mkdir "$swift_scratch"
fi
# Assemble a new bundle; retain the previous artifact for review/rollback.
final_app_dir="$app_dir"
assembly_root="$(mktemp -d "$repo_dir/build/.bundle-XXXXXXXX")"
app_dir="$assembly_root/${final_app_dir:t}"
cd "$repo_dir"
swift build --disable-sandbox --scratch-path "$swift_scratch" -c "$configuration" --product AIMMac
swift build --disable-sandbox --scratch-path "$swift_scratch" -c "$configuration" --product AIMAgentHost
bin_dir="$(swift build --disable-sandbox --scratch-path "$swift_scratch" -c "$configuration" --show-bin-path)"
contents="$app_dir/Contents"
sign_entitlements="$repo_dir/Config/AIMMac.entitlements"
if [[ "${AIM_ENABLE_VIRTUALIZATION:-0}" != "0" && "${AIM_ENABLE_VIRTUALIZATION:-0}" != "1" ]]; then
  echo "AIM_ENABLE_VIRTUALIZATION must be explicitly 0 or 1" >&2
  exit 2
fi
if [[ "${AIM_ENABLE_VIRTUALIZATION:-0}" == "1" ]]; then
  sign_entitlements="$assembly_root/AIMMac-Virtualization.entitlements"
  cp "$repo_dir/Config/AIMMac.entitlements" "$sign_entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.virtualization bool true" "$sign_entitlements"
fi

mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"
if [[ -d "$repo_dir/scripts/adapters" ]]; then
  mkdir -p "$contents/Resources/AgentBridges"
  cp -R "$repo_dir/scripts/adapters/hermes" "$contents/Resources/AgentBridges/hermes"
  cp -R "$repo_dir/scripts/adapters/openclaw" "$contents/Resources/AgentBridges/openclaw"
  find "$contents/Resources/AgentBridges" -type d -name __pycache__ -exec rm -rf '{}' +
fi
cp "$bin_dir/AIMMac" "$contents/MacOS/AIMMac"
cp "$repo_dir/Config/Info.plist" "$contents/Info.plist"
if [[ "${AIM_ENABLE_VIRTUALIZATION:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Add :AIMVirtualizationBuildEnabled bool true" "$contents/Info.plist"
fi
agent_host="$contents/Library/LoginItems/AIMAgentHost.app/Contents"
mkdir -p "$agent_host/MacOS" "$contents/Library/LaunchAgents"
cp "$bin_dir/AIMAgentHost" "$agent_host/MacOS/AIMAgentHost"
cp "$repo_dir/Config/AgentHostInfo.plist" "$agent_host/Info.plist"
if [[ -n "${AIM_RELEASE_VERSION:-}" || -n "${AIM_RELEASE_BUILD:-}" ]]; then
  if [[ "$configuration" != "release" || "$qualification" == true ]]; then
    echo "Reviewed release version overrides require an official Release build" >&2
    exit 2
  fi
  /usr/bin/python3 - "$contents/Info.plist" "$agent_host/Info.plist" <<'PY'
import os, plistlib, re, sys
version = os.environ.get('AIM_RELEASE_VERSION', '')
build = os.environ.get('AIM_RELEASE_BUILD', '')
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version) or not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('A valid reviewed release version and positive integer build are required')
for path in sys.argv[1:]:
    with open(path, 'rb') as f: info = plistlib.load(f)
    info['CFBundleShortVersionString'] = version
    info['CFBundleVersion'] = build
    with open(path, 'wb') as f: plistlib.dump(info, f)
PY
fi
cp "$repo_dir/Config/com.aimai.macos.agenthost.plist" "$contents/Library/LaunchAgents/"
if [[ "$qualification" == true ]]; then
  /usr/bin/python3 - "$app_dir" "$qualification_namespace" <<'QUALIFICATION_PLISTS'
import pathlib, plistlib, sys
root, namespace = pathlib.Path(sys.argv[1]), sys.argv[2]
main = root / 'Contents/Info.plist'
helper = root / 'Contents/Library/LoginItems/AIMAgentHost.app/Contents/Info.plist'
for file, identifier, name in [(main, namespace, 'AIM Continuity Test'),
                              (helper, namespace + '.agenthost', 'AIM Continuity Test Host')]:
    info = plistlib.loads(file.read_bytes())
    info.update(CFBundleIdentifier=identifier, CFBundleName=name, CFBundleDisplayName=name,
                AIMQualificationNamespace=namespace)
    # Qualification never contacts Sparkle's production feed.
    for key in ('SUFeedURL', 'SUPublicEDKey'): info.pop(key, None)
    if file == main: info.pop('CFBundleURLTypes', None)
    file.write_bytes(plistlib.dumps(info))
old = root / 'Contents/Library/LaunchAgents/com.aimai.macos.agenthost.plist'
info = plistlib.loads(old.read_bytes())
info['Label'] = namespace + '.agenthost'
info['MachServices'] = {namespace + '.agenthost': True}
new = old.with_name(namespace + '.agenthost.plist')
new.write_bytes(plistlib.dumps(info)); old.unlink()
QUALIFICATION_PLISTS
fi
if [[ "${AIM_QUALIFICATION_NSXPC:-0}" == "1" && "$configuration" == "debug" ]]; then
  # Fixture-only registration test: no user database, account, keys or desktop.
  /usr/bin/python3 - "$app_dir" "$final_app_dir" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
name = 'com.aimai.macos.agenthost.qualification.smappservice'
plist = {'Label': name, 'BundleProgram': 'Contents/Library/LoginItems/AIMAgentHost.app/Contents/MacOS/AIMAgentHost',
         'ProgramArguments': ['AIMAgentHost', '--xpc-qualification-server', name, sys.argv[2]],
         'MachServices': {name: True}, 'RunAtLoad': True, 'LimitLoadToSessionType': 'Aqua'}
(root / 'Contents/Library/LaunchAgents' / (name + '.plist')).write_bytes(plistlib.dumps(plist))
PY
fi
install_name_tool -add_rpath '@executable_path/../../../../../Frameworks' "$agent_host/MacOS/AIMAgentHost"
# CUA capabilities qualified on reference Macs (see CuaReleaseManifest); optional.
if [[ -f "$repo_dir/Config/CuaQualificationManifest.json" ]]; then
  cp "$repo_dir/Config/CuaQualificationManifest.json" "$contents/Resources/CuaQualificationManifest.json"
fi
if [[ "${AIM_CODESIGN_IDENTITY:--}" == "-" ]]; then
  /usr/libexec/PlistBuddy -c "Add :AIMAdHocSigned bool true" "$contents/Info.plist"
fi

# Browser automation runs the pinned official Playwright MCP server locally.
# Release builders provide AIM_NODE_RUNTIME; users never need Node installed.
playwright_modules="${AIM_PLAYWRIGHT_MODULES:-$repo_dir/Vendor/PlaywrightMCP/node_modules}"
node_license="${AIM_NODE_LICENSE:-}"
if [[ -n "${AIM_PLAYWRIGHT_MODULES:-}${AIM_NODE_RUNTIME:-}${AIM_NODE_LICENSE:-}" ]] && [[ ! -x "${AIM_NODE_RUNTIME:-}" || ! -s "$node_license" || ! -f "$playwright_modules/@playwright/mcp/cli.js" ]]; then
  echo "Explicit Playwright inputs require executable Node, full Node license and complete modules" >&2
  exit 1
fi
node_runtime="${AIM_NODE_RUNTIME:-$(command -v node || true)}"
# A package-manager Node (Homebrew) links its own libnode*.dylib, absent from the app: the browser
# server would die at launch ("The Playwright browser connection stopped"). Only a self-contained
# runtime (the official nodejs.org binary) may be bundled.
if [[ -n "$node_runtime" && -x "$node_runtime" ]] && otool -L "$node_runtime" | tail -n +2 | awk '{print $1}' | grep -qvE '^(/System/|/usr/lib/)'; then
  echo "Error: $node_runtime is not self-contained (it links $(otool -L "$node_runtime" | tail -n +2 | awk '{print $1}' | grep -vE '^(/System/|/usr/lib/)' | head -1)). Set AIM_NODE_RUNTIME to the official Node binary." >&2
  exit 1
fi
if [[ -n "$node_runtime" && -x "$node_runtime" && -f "$playwright_modules/@playwright/mcp/cli.js" ]]; then
  /usr/bin/python3 "$repo_dir/scripts/release/prepare-runtime-inputs.py" copy \
    --node "$node_runtime" --node-license "$node_license" --modules "$playwright_modules" \
    --destination "$contents/Resources/Playwright"
  codesign --force --options runtime "${sign_timestamp[@]}" --entitlements "$repo_dir/Config/PlaywrightNode.entitlements" --sign "${AIM_CODESIGN_IDENTITY:--}" "$contents/Resources/Playwright/node"
else
  echo "Warning: Playwright browser automation omitted. Install Vendor/PlaywrightMCP and provide AIM_NODE_RUNTIME to bundle it." >&2
fi

# Optional CUA Driver candidate. The build input is pinned to the qualified
# upstream 0.28.2 executable; the nested copy is signed with the host bundle.
# No driver process starts merely because the resource is present.
if [[ -n "${AIM_CUA_DRIVER_PATH:-}" ]]; then
  cua_source="${AIM_CUA_DRIVER_PATH:A}"
  cua_license="${AIM_CUA_DRIVER_LICENSE:-}"
  if [[ ! -x "$cua_source" || -z "$cua_license" || ! -f "$cua_license" ]]; then
    echo "AIM_CUA_DRIVER_PATH must be executable and AIM_CUA_DRIVER_LICENSE must name its MIT license" >&2
    exit 2
  fi
  cua_checksum="$(shasum -a 256 "$cua_source" | awk '{print $1}')"
  if [[ "$cua_checksum" != "af30d29cf33bd3bbda1330be7225b18881ea4c5af6df374e08627914b5ac334d" ]]; then
    echo "CUA Driver binary differs from the pinned 0.28.2 candidate" >&2
    exit 2
  fi
  mkdir -p "$contents/Resources/CuaDriver"
  cp "$cua_source" "$contents/Resources/CuaDriver/cua-driver"
  cp "$cua_license" "$contents/Resources/CuaDriver/LICENSE.md"
  chmod 755 "$contents/Resources/CuaDriver/cua-driver"
  # Upstream CUA has build-machine Xcode runpaths despite system-only deps.
  # Edit only our copy, preserving every dependency, minimum OS and code section.
  /usr/bin/python3 "$script_dir/release/verify-candidate-runtime.py" portable-system-rpaths "$contents/Resources/CuaDriver/cua-driver"
  # Re-signing replaces the upstream signature; keep exactly its entitlements.
  cua_upstream_entitlements="$(codesign -d --entitlements - --xml "$cua_source" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
  cua_expected_entitlements="$(plutil -convert xml1 -o - "$repo_dir/Config/CuaDriver.entitlements")"
  if [[ "$cua_upstream_entitlements" != "$cua_expected_entitlements" ]]; then
    echo "CUA Driver entitlements differ from Config/CuaDriver.entitlements" >&2
    exit 2
  fi
  codesign --force --options runtime "${sign_timestamp[@]}" --entitlements "$repo_dir/Config/CuaDriver.entitlements" \
    --sign "${AIM_CODESIGN_IDENTITY:--}" "$contents/Resources/CuaDriver/cua-driver"
fi

# Built-in local models: the official llama.cpp server (MIT, Metal), started by AIM only
# when a local model is chosen. AIM_LLAMA_CPP_DIR is an unpacked macOS arm64 release.
if [[ -n "${AIM_LLAMA_CPP_DIR:-}" ]]; then
  llama_source="${AIM_LLAMA_CPP_DIR:A}"
  if [[ ! -x "$llama_source/llama-server" || ! -f "$llama_source/LICENSE" ]]; then
    echo "AIM_LLAMA_CPP_DIR must contain llama-server and its LICENSE" >&2
    exit 2
  fi
  llama_dest="$contents/Resources/LlamaCpp"
  mkdir -p "$llama_dest"
  cp "$llama_source/llama-server" "$llama_dest/llama-server"
  cp "$llama_source/LICENSE" "$llama_dest/LICENSE"
  for lib in libllama-server-impl.dylib libllama-common.0.dylib libmtmd.0.dylib libllama.0.dylib libggml.0.dylib \
             libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib libggml-rpc.0.dylib libggml-base.0.dylib; do
    cp -L "$llama_source/$lib" "$llama_dest/$lib"
    codesign --force --options runtime "${sign_timestamp[@]}" --sign "${AIM_CODESIGN_IDENTITY:--}" "$llama_dest/$lib"
  done
  chmod 755 "$llama_dest/llama-server"
  codesign --force --options runtime "${sign_timestamp[@]}" --sign "${AIM_CODESIGN_IDENTITY:--}" "$llama_dest/llama-server"
else
  echo "Warning: built-in local models omitted. Provide AIM_LLAMA_CPP_DIR to bundle llama.cpp." >&2
fi

# Built-in MLX engine (Vendor/AIMMLXEngine, built by scripts/build-mlx-engine.sh with xcodebuild):
# the program plus the resource bundles it loads from its own folder (Metal library, tokenizer data).
if [[ -n "${AIM_MLX_ENGINE_DIR:-}" ]]; then
  mlx_source="${AIM_MLX_ENGINE_DIR:A}"
  if [[ ! -x "$mlx_source/aim-mlx-engine" || ! -f "$mlx_source/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
    echo "AIM_MLX_ENGINE_DIR must contain aim-mlx-engine and mlx-swift_Cmlx.bundle" >&2
    exit 2
  fi
  python3 "$script_dir/verify-mlx-license-bundle.py" "$mlx_source"
  mlx_dest="$contents/Resources/MLXEngine"
  mkdir -p "$mlx_dest"
  cp "$mlx_source/Package.resolved" "$mlx_dest/Package.resolved"
  cp -R "$mlx_source/Licenses" "$mlx_dest/Licenses"
  cp "$mlx_source/aim-mlx-engine" "$mlx_dest/aim-mlx-engine"
  for bundle in "$mlx_source"/*.bundle; do cp -R "$bundle" "$mlx_dest/"; done
  chmod 755 "$mlx_dest/aim-mlx-engine"
  /usr/bin/python3 "$script_dir/release/verify-candidate-runtime.py" embed-swift "$app_dir" --scan "$mlx_dest/aim-mlx-engine"
  codesign --force --options runtime "${sign_timestamp[@]}" --sign "${AIM_CODESIGN_IDENTITY:--}" "$mlx_dest/aim-mlx-engine"
else
  echo "Warning: built-in MLX engine omitted. Run scripts/build-mlx-engine.sh and provide AIM_MLX_ENGINE_DIR." >&2
fi

# Both values are public Supabase client configuration, never a service-role key.
# Optional for local/BYOC-only development builds.
if [[ "$supabase_configured" == true ]]; then
  /usr/libexec/PlistBuddy -c "Add :AIMSupabaseURL string $AIM_SUPABASE_URL" "$contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :AIMSupabasePublicKey string $AIM_SUPABASE_PUBLIC_KEY" "$contents/Info.plist"
fi

find "$bin_dir" -maxdepth 1 -type d -name '*.bundle' -exec cp -R '{}' "$contents/Resources/" \;
if [[ -d "$bin_dir/Sparkle.framework" ]]; then
  cp -R "$bin_dir/Sparkle.framework" "$contents/Frameworks/"
  if ! otool -l "$contents/MacOS/AIMMac" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$contents/MacOS/AIMMac"
  fi
fi

# macOS accepts a high-resolution PNG bundle icon. This is intentionally used
# instead of iconutil because current Xcode 27 toolchains reject otherwise
# valid legacy .iconset folders on some macOS installations.
cp "$repo_dir/Sources/AIMMac/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" \
  "$contents/Resources/AppIcon.png"

if [[ "$qualification" == false && -n "${AIM_SPARKLE_FEED_URL:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $AIM_SPARKLE_FEED_URL" "$contents/Info.plist"
fi
if [[ "$qualification" == false && -n "${AIM_SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $AIM_SPARKLE_PUBLIC_KEY" "$contents/Info.plist"
fi

# Resolve Apple-selected Swift backdeployment libraries before final nested signatures.
/usr/bin/python3 "$script_dir/release/verify-candidate-runtime.py" embed-swift "$app_dir" \
  --scan "$contents/MacOS/AIMMac" --scan "$agent_host/MacOS/AIMAgentHost"
if [[ "$configuration" == "release" ]]; then
  /usr/bin/python3 "$script_dir/release/verify-candidate-runtime.py" portable-apple-rpaths "$app_dir" \
    --scan "$contents/MacOS/AIMMac" --scan "$agent_host/MacOS/AIMAgentHost"
fi
for swift_library in "$contents/Frameworks"/libswift*.dylib(N); do
  codesign --force --options runtime "${sign_timestamp[@]}" --sign "$identity" "$swift_library"
done
codesign --force --options runtime "${sign_timestamp[@]}" --entitlements "$sign_entitlements" \
  --sign "$identity" "${agent_host:h}"
if [[ -d "$contents/Frameworks/Sparkle.framework" ]]; then
  codesign --force --deep --preserve-metadata=entitlements --options runtime "${sign_timestamp[@]}" --sign "$identity" "$contents/Frameworks/Sparkle.framework"
fi
if [[ "$identity" == "-" ]]; then
  codesign --force --deep "${sign_timestamp[@]}" --entitlements "$sign_entitlements" --sign - "$app_dir"
else
  codesign --force --deep --options runtime "${sign_timestamp[@]}" --entitlements "$sign_entitlements" --sign "$identity" "$app_dir"
fi
codesign --verify --deep --strict --verbose=2 "$app_dir"
if [[ "${AIM_ENABLE_VIRTUALIZATION:-0}" == "1" ]]; then
  for vm_signed_target in "$app_dir" "${agent_host:h}"; do
    vm_entitlement="$(codesign -d --entitlements - --xml "$vm_signed_target" 2>/dev/null | /usr/bin/python3 -c 'import plistlib,sys; print("true" if plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.virtualization") is True else "false")' 2>/dev/null || true)"
    if [[ "$vm_entitlement" != "true" ]]; then
      echo "Signed application/helper lacks its explicitly requested virtualization entitlement" >&2
      exit 3
    fi
  done
fi
# Nested helpers keep their own entitlements through the outer signature.
if [[ -x "$contents/Resources/CuaDriver/cua-driver" ]]; then
  nested_cua="$(codesign -d --entitlements - --xml "$contents/Resources/CuaDriver/cua-driver" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
  if [[ "$nested_cua" != "$(plutil -convert xml1 -o - "$repo_dir/Config/CuaDriver.entitlements")" ]]; then
    echo "Signed CUA Driver lost its entitlements" >&2
    exit 3
  fi
fi
if [[ -x "$contents/Resources/Playwright/node" ]]; then
  nested_node="$(codesign -d --entitlements - --xml "$contents/Resources/Playwright/node" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
  if [[ "$nested_node" != "$(plutil -convert xml1 -o - "$repo_dir/Config/PlaywrightNode.entitlements")" ]]; then
    echo "Signed Node runtime lost its entitlements" >&2
    exit 3
  fi
fi
if [[ "$configuration" == "release" ]]; then
  /usr/bin/python3 "$script_dir/distribution-tools.py" verify "$app_dir"
fi
/usr/bin/python3 "$script_dir/distribution-tools.py" guard "${guard_flags[@]}" "$final_app_dir" "$swift_scratch"
if [[ ( "$qualification" == true || -n "$explicit_scratch" ) && ( -e "$final_app_dir" || -L "$final_app_dir" ) ]]; then
  echo "Qualification destination appeared during assembly; refusing replacement" >&2
  exit 2
fi
if [[ -e "$final_app_dir" ]]; then
  previous_root="$(mktemp -d "$repo_dir/build/.previous-XXXXXXXX")"
  mv "$final_app_dir" "$previous_root/${final_app_dir:t}"
  echo "Previous bundle preserved: $previous_root/${final_app_dir:t}" >&2
fi
if [[ "$qualification" == true || -n "$explicit_scratch" ]]; then
  /usr/bin/python3 "$script_dir/distribution-tools.py" publish-new "$app_dir" "$final_app_dir"
else
  mv "$app_dir" "$final_app_dir"
fi
if [[ "$sign_entitlements" == "$assembly_root/"* ]]; then rm "$sign_entitlements"; fi
rmdir "$assembly_root"
receipt_args=(--stage built --repository "$repo_dir" --output "$final_app_dir.receipt-$(date -u +%Y%m%dT%H%M%SZ)-$$.json")
if [[ "$configuration" == "release" ]]; then receipt_args+=(--release); fi
/usr/bin/python3 "$script_dir/distribution-tools.py" receipt "$final_app_dir" "${receipt_args[@]}"
echo "$final_app_dir"
