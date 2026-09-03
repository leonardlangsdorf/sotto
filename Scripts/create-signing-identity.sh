#!/usr/bin/env bash
# Creates a self-signed code signing certificate so Sotto's Accessibility grant
# survives rebuilds. Run once.
#
# Why this is needed: macOS grants Accessibility to a code signature, not a file
# path. Ad-hoc signing produces a new identity on every build, so the grant is
# silently revoked and the hotkey stops working with no error.
#
# Signing with a certificate fixes that. The designated requirement becomes
#     identifier "com.langsdorf.sotto" and certificate leaf = H"<cert hash>"
# which stays identical across rebuilds even as the binary's cdhash changes.
#
# The certificate does NOT need to be trusted by the system, so this needs no
# admin password. macOS may show one keychain prompt for your login password
# when granting codesign access to the new key.
#
# To undo: open Keychain Access, find "Sotto Local Signing", delete it.
set -euo pipefail

NAME="Sotto Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXPORT_PHRASE="$(openssl rand -base64 32)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# macOS's Security framework cannot read OpenSSL 3's default PKCS#12 encoding.
# SHA-1 MAC with 3DES PBE is what `security import` accepts.
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout "pass:$EXPORT_PHRASE" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -legacy 2>/dev/null

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$EXPORT_PHRASE" \
    -T /usr/bin/codesign

# Let codesign use the key without a prompt on every build. This is the step
# that may ask for your login password.
echo "Granting codesign access to the new key (login password prompt may follow)…"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
    || echo "note: could not preauthorize the key; codesign may prompt on first build."

echo
security find-identity -p codesigning | grep "$NAME" || true
echo
echo "Done. Now run Scripts/build.sh, then grant Accessibility ONE more time"
echo "(the signature changed). It will persist across every rebuild after that."
