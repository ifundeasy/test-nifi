#!/usr/bin/env bash
set -euo pipefail

# Creates an admin client certificate for browser mTLS login:
#   pki/client/admin.p12
# Also outputs CA cert path so you can import it as Trusted Root on Windows.

PKI_DIR="${PKI_DIR:-./pki}"
CA_DIR="${CA_DIR:-$PKI_DIR/ca}"
CLIENT_DIR="${CLIENT_DIR:-$PKI_DIR/client}"
PW="${PW:-}"
FORCE="${FORCE:-0}"

if [[ -z "$PW" ]]; then
  echo "[ERROR] PW is empty. Example: PW='ChangeMe123456' $0"
  exit 1
fi

CA_KEY="$CA_DIR/ca.key"
CA_CRT="$CA_DIR/ca.crt"

if [[ ! -f "$CA_KEY" || ! -f "$CA_CRT" ]]; then
  echo "[ERROR] CA not found at $CA_DIR. Run ./01-init-ca.sh first."
  exit 1
fi

mkdir -p "$CLIENT_DIR"

KEY="$CLIENT_DIR/admin.key"
CSR="$CLIENT_DIR/admin.csr"
CRT="$CLIENT_DIR/admin.crt"
P12="$CLIENT_DIR/admin.p12"
CNF="$CLIENT_DIR/openssl.cnf"

if [[ -f "$P12" && "$FORCE" != "1" ]]; then
  echo "[OK] Client cert already exists: $P12"
  echo "     (Set FORCE=1 to regenerate.)"
  exit 0
fi

if [[ "$FORCE" == "1" ]]; then
  rm -f "$KEY" "$CSR" "$CRT" "$P12" "$CNF"
fi

cat > "$CNF" <<EOF
[ req ]
prompt = no
distinguished_name = dn
req_extensions = req_ext

[ dn ]
CN = admin
OU = NIFI

[ req_ext ]
extendedKeyUsage = clientAuth
EOF

openssl genrsa -out "$KEY" 2048
openssl req -new -key "$KEY" -out "$CSR" -config "$CNF"

openssl x509 -req -in "$CSR" \
  -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$CRT" -days 825 -sha256 \
  -extensions req_ext -extfile "$CNF"

openssl pkcs12 -export \
  -out "$P12" \
  -inkey "$KEY" \
  -in "$CRT" \
  -certfile "$CA_CRT" \
  -name admin \
  -passout "pass:${PW}"

echo "[DONE] Admin client certificate created:"
echo "  - $P12"
echo
echo "[NEXT] Import these on Windows:"
echo "  1) CA cert as Trusted Root: $CA_CRT"
echo "  2) Client cert as Personal: $P12 (password = PW)"
echo
echo "[NOTE] In NiFi compose, set:"
echo "  INITIAL_ADMIN_IDENTITY: \"CN=admin, OU=NIFI\""
