#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(dirname "$script_directory")"
derived_data_directory="$repository_directory/DerivedData-Install"
if [[ -n "${AI_USAGE_INSTALL_DIR:-}" ]]; then
    install_directory="$AI_USAGE_INSTALL_DIR"
elif [[ -w "/Applications" ]]; then
    install_directory="/Applications"
else
    install_directory="${HOME}/Applications"
fi
built_application="$derived_data_directory/Build/Products/Release/AI Usage.app"
installed_application="$install_directory/AI Usage.app"

if ! command -v xcodebuild >/dev/null 2>&1; then
    printf 'AI Usage requires Xcode 27 or newer.\n' >&2
    exit 1
fi

printf 'Building AI Usage…\n'
xcodebuild \
    -quiet \
    -project "$repository_directory/AIUsage.xcodeproj" \
    -scheme AIUsage \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_directory" \
    ENABLE_HARDENED_RUNTIME=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build

if [[ "${AI_USAGE_SKIP_OPEN:-0}" != "1" ]]; then
    osascript -e 'if application id "com.burakgon.aiusage" is running then tell application id "com.burakgon.aiusage" to quit' >/dev/null 2>&1 || true
    for _ in {1..30}; do
        pgrep -x "AI Usage" >/dev/null 2>&1 || break
        sleep 0.1
    done
fi

mkdir -p "$install_directory"
rm -rf "$installed_application"
/usr/bin/ditto "$built_application" "$installed_application"

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
    shopt -s nullglob
    for candidate in "$repository_directory"/DerivedData-*/Build/Products/*/"AI Usage.app"; do
        "$lsregister" -u "$candidate" >/dev/null 2>&1 || true
    done
    shopt -u nullglob
    "$lsregister" -u "$built_application" >/dev/null 2>&1 || true
    "$lsregister" -f "$installed_application" >/dev/null 2>&1 || true
fi

if [[ "${AI_USAGE_SKIP_OPEN:-0}" != "1" ]]; then
    open "$installed_application"
fi

printf 'Installed AI Usage at %s\n' "$installed_application"
