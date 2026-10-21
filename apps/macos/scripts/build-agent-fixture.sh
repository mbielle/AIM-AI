#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h}"
app_dir="$repo_dir/build/AgentFixture.app"
mkdir -p "$app_dir/Contents/MacOS"
swiftc -parse-as-library "$repo_dir/scripts/agent-fixture.swift" -o "$app_dir/Contents/MacOS/AgentFixture" -target arm64-apple-macos14
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.aimai.macos.agent-fixture</string>
<key>CFBundleExecutable</key><string>AgentFixture</string>
<key>CFBundleName</key><string>AIM Agent Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign "${AIM_CODESIGN_IDENTITY:--}" "$app_dir"
codesign --verify --strict "$app_dir"
echo "$app_dir"
