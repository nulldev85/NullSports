#!/usr/bin/env bash
# Signs an unsigned build ad hoc with the App Group, so the IPA carries it.
#
# The IPAs are built with signing off, which leaves no entitlements in them,
# and a sideloading tool signs an app with the entitlements it finds inside:
# none. The app and its extension then share no App Group, and the widget or
# the Top Shelf has nowhere to read the app's games from. An ad-hoc signature
# carrying only the group puts it where those tools look. They replace the
# signature itself when they sign, keeping the entitlements -- or, like
# AltStore, renaming the group, which the app finds again at launch (see
# LineupAppGroup in Shared/HomeShelf.swift).
#
# iCloud is left out on purpose: unsigned builds do not sync, and asking a
# free signing account for iCloud makes the install fail.
#
# Usage: Tools/carry-app-group.sh path/to/Lineup.app
set -euo pipefail

app="$1"
group="group.com.nulldev85.NullSports"
test -d "$app"

entitlements="$(mktemp -t lineup-app-group)"
cat > "$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.application-groups</key>
    <array><string>$group</string></array>
</dict></plist>
PLIST

# Inside out: a bundle's signature covers what it contains, so frameworks
# first, then each extension, then the app.
find "$app" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
    while IFS= read -r -d '' code; do
        codesign --force --sign - "$code"
    done
for extension in "$app"/PlugIns/*.appex; do
    [ -d "$extension" ] || continue
    codesign --force --sign - --entitlements "$entitlements" "$extension"
done
codesign --force --sign - --entitlements "$entitlements" "$app"

for code in "$app" "$app"/PlugIns/*.appex; do
    [ -d "$code" ] || continue
    if ! codesign -d --entitlements - --xml "$code" 2>/dev/null | grep -q "$group"; then
        echo "$code does not carry $group"
        exit 1
    fi
done
echo "App Group carried by $app and its extensions"
