#!/usr/bin/env bash
# Creates a self-signed code signing certificate so Sotto's Accessibility grant
# survives rebuilds. Run once.
#
# This adds a certificate to your *login* keychain and marks it trusted for code
# signing. macOS will prompt for your password — that prompt is this script
# asking to trust the certificate it just created. Nothing leaves the machine.
#
# To undo: open Keychain Access, find "Sotto Local Signing", delete it.
set -euo pipefail

NAME="Sotto Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass: 2>/dev/null

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" \
    -T /usr/bin/codesign -T /usr/bin/security

# Allow codesign to use the key without prompting on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "Created '$NAME'. Trusting it for code signing (password prompt follows)…"
security add-trusted-cert -d -r trustRoot \
    -p codeSign -k /Library/Keychains/System.keychain "$WORK/cert.pem"

echo
security find-identity -v -p codesigning
echo
echo "Done. Rebuild with Scripts/build.sh — the Accessibility grant will now persist."
