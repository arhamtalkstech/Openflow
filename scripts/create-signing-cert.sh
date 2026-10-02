#!/usr/bin/env bash
# Creates a self-signed "Openflow Local Signing" code-signing identity in your login keychain.
# Why: ad-hoc signatures change on every build, so macOS forgets the Accessibility and Microphone
# grants each time. A stable certificate keeps them. Remove later with:
#   security delete-identity -c "Openflow Local Signing"
set -euo pipefail
NAME="Openflow Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<EOF
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
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:openflow
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P openflow -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with scripts/build-app.sh --install."
