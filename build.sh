#!/bin/zsh
# ClaudeUsage.app 빌드 → ~/Applications 에 설치
# Apple Silicon + Intel 모두에서 실행되는 유니버설 바이너리로 빌드합니다.
set -e
cd "$(dirname "$0")"

# Xcode 라이선스 미동의 상태에서도 빌드되도록 Command Line Tools 우선 사용
if [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
command -v swiftc >/dev/null || {
  echo "swiftc가 없습니다. 먼저 실행하세요: xcode-select --install"; exit 1; }

APP="build/ClaudeUsage.app"
BIN="$APP/Contents/MacOS/ClaudeUsage"
rm -rf build && mkdir -p "$APP/Contents/MacOS"

echo "빌드 중 (arm64)..."
swiftc -O -target arm64-apple-macos13 -o build/ClaudeUsage-arm64 main.swift
echo "빌드 중 (x86_64)..."
swiftc -O -target x86_64-apple-macos13 -o build/ClaudeUsage-x86_64 main.swift
lipo -create -output "$BIN" build/ClaudeUsage-arm64 build/ClaudeUsage-x86_64
rm build/ClaudeUsage-arm64 build/ClaudeUsage-x86_64

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.claude-usage-widget</string>
  <key>CFBundleName</key><string>ClaudeUsage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

pkill -x ClaudeUsage 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/ClaudeUsage.app
cp -R "$APP" ~/Applications/
echo "설치 완료: ~/Applications/ClaudeUsage.app"
echo "실행: open ~/Applications/ClaudeUsage.app"
