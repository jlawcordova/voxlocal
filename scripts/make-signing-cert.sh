#!/bin/bash
# Creates a local, self-signed code-signing identity named "Voxlocal Dev" in your
# login keychain. Signing every build with the same identity keeps macOS's
# Accessibility and Microphone grants valid across rebuilds. Ad-hoc signed builds
# get a new identity each time, so macOS drops the grants.
#
# The certificate never leaves this machine. Remove it any time with:
#   security delete-identity -c "Voxlocal Dev"
set -euo pipefail

NAME="Voxlocal Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
    -days 3650 -config cert.cnf >/dev/null 2>&1
PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 \
    -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PASS"

security import id.p12 -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with: make install"
