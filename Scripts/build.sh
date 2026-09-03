#!/usr/bin/env bash
# Builds Sotto.app.
#
# Accessibility permission is granted to a code *signature*, not a path. If this
# script falls back to ad-hoc signing, every rebuild produces a new identity and
# macOS silently revokes the grant — the hotkey stops working with no error and
# no log line. Run Scripts/create-signing-identity.sh once to avoid that.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
BUNDLE_ID="com.langsdorf.sotto"
LOCAL_IDENTITY="Sotto Local Signing"

pick_identity() {
    if [[ -n "${SOTTO_SIGN_IDENTITY:-}" ]]; then
        echo "$SOTTO_SIGN_IDENTITY"
        return
    fi
    # Our self-signed cert is deliberately untrusted, so it appears under
    # "Matching identities" but not "Valid identities only" — hence no -v here.
    if security find-identity -p codesigning 2>/dev/null | grep -q "$LOCAL_IDENTITY"; then
        echo "$LOCAL_IDENTITY"
        return
    fi
    # `|| true`: grep exits 1 when there is no identity, and with pipefail that
    # would abort the whole script before it could fall back to ad-hoc.
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"[^"]+"' | head -1 | tr -d '"' || true
}

IDENTITY="$(pick_identity)"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "warning: no code signing identity found; signing ad-hoc."
    echo "         Accessibility permission will be revoked on every rebuild."
    echo "         Fix once with: Scripts/create-signing-identity.sh"
fi

swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Sotto.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/SottoApp" "$APP/Contents/MacOS/Sotto"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --entitlements Resources/Sotto.entitlements \
    --options runtime \
    --timestamp=none \
    "$APP"

echo "Built $APP  (signed with: $IDENTITY)"
codesign -d -r- "$APP" 2>&1 | grep "designated" || true
