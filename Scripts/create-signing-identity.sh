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
# The certificate does NOT need to be trusted by the system, so no admin
# password is required. macOS may show one login-password keychain prompt.
#
# To undo: open Keychain Access, find "Sotto Local Signing", delete it.
#
# Set SOTTO_KEYCHAIN to target a different keychain (used by the test below).
set -euo pipefail

NAME="Sotto Local Signing"
KEYCHAIN="${SOTTO_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
EXPORT_PHRASE="$(openssl rand -base64 32)"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists in $KEYCHAIN. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "1/3  Generating a self-signed code signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# macOS's Security framework cannot read OpenSSL 3's default PKCS#12 encoding.
# SHA-1 MAC with 3DES PBE is what `security import` accepts. Without these
# flags the import fails with "MAC verification failed".
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout "pass:$EXPORT_PHRASE" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -legacy

echo "2/3  Importing into ${KEYCHAIN}…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$EXPORT_PHRASE" \
    -T /usr/bin/codesign

echo "3/3  Granting codesign access to the key (password prompt may follow)…"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
    || echo "     note: could not preauthorize; codesign may prompt on first build."

echo
if security find-identity -p codesigning "$KEYCHAIN" | grep "$NAME"; then
    echo
    echo "Done. Run Scripts/build.sh, then grant Accessibility ONE more time"
    echo "(the signature changed). It persists across every rebuild after that."
else
    echo "FAILED: the identity was not created. Output above should say why."
    exit 1
fi
