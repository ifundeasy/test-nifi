#!/usr/bin/env bash
set -euo pipefail

# Adds one or more NiFi nodes (nifi4 later is fine).
# Generates:
#   pki/<node>/keystore.jks
#   pki/<node>/truststore.jks (contains the CA cert)
#
# Usage:
#   PW='ChangeMe123456' ./02-add-nodes.sh nifi1 nifi2 nifi3
#   PW='ChangeMe123456' ./02-add-nodes.sh nifi4
#
# Optional env:
#   PKI_DIR=./pki
#   EXTRA_DNS="myhost.local,internal.example"
#   EXTRA_IP="10.0.0.10,10.0.0.11"
#   FORCE=1  (regenerate node materials)

PKI_DIR="${PKI_DIR:-./pki}"
CA_DIR="${CA_DIR:-$PKI_DIR/ca}"
PW="${PW:-}"
FORCE="${FORCE:-0}"

EXTRA_DNS="${EXTRA_DNS:-}"   # comma-separated
EXTRA_IP="${EXTRA_IP:-}"     # comma-separated

if [[ -z "$PW" ]]; then
  echo "[ERROR] PW is empty. Example: PW='ChangeMe123456' $0 nifi1 nifi2"
  exit 1
fi

CA_KEY="$CA_DIR/ca.key"
CA_CRT="$CA_DIR/ca.crt"

if [[ ! -f "$CA_KEY" || ! -f "$CA_CRT" ]]; then
  echo "[ERROR] CA not found at $CA_DIR. Run ./01-init-ca.sh first."
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "[ERROR] Provide at least one node name. Example: $0 nifi1 nifi2 nifi3"
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing command: $1"; exit 1; }; }
need_cmd openssl
need_cmd docker

keytool() {
  # run keytool inside Java container
  docker run --rm \
    -v "$(pwd):/work" \
    -w /work \
    eclipse-temurin:21-jre \
    keytool "$@"
}

make_openssl_cnf() {
  local node="$1"
  local cnf="$2"

  # Build SAN list
  local dns_lines=()
  local ip_lines=()

  dns_lines+=( "DNS.1 = ${node}" )
  dns_lines+=( "DNS.2 = localhost" )
  ip_lines+=(  "IP.1  = 127.0.0.1" )

  # Add extra DNS if provided
  if [[ -n "$EXTRA_DNS" ]]; then
    IFS=',' read -r -a extra_dns_arr <<< "$EXTRA_DNS"
    local i=3
    for d in "${extra_dns_arr[@]}"; do
      d="$(echo "$d" | xargs)"
      [[ -z "$d" ]] && continue
      dns_lines+=( "DNS.${i} = ${d}" )
      i=$((i+1))
    done
  fi

  # Add extra IP if provided
  if [[ -n "$EXTRA_IP" ]]; then
    IFS=',' read -r -a extra_ip_arr <<< "$EXTRA_IP"
    local i=2
    for ip in "${extra_ip_arr[@]}"; do
      ip="$(echo "$ip" | xargs)"
      [[ -z "$ip" ]] && continue
      ip_lines+=( "IP.${i}  = ${ip}" )
      i=$((i+1))
    done
  fi

  cat > "$cnf" <<EOF
[ req ]
prompt = no
distinguished_name = dn
req_extensions = req_ext

[ dn ]
CN = ${node}
OU = NIFI

[ req_ext ]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth, clientAuth

[ alt_names ]
$(printf "%s\n" "${dns_lines[@]}")
$(printf "%s\n" "${ip_lines[@]}")
EOF
}

for NODE in "$@"; do
  NODE_DIR="$PKI_DIR/$NODE"
  mkdir -p "$NODE_DIR"

  KEY="$NODE_DIR/${NODE}.key"
  CSR="$NODE_DIR/${NODE}.csr"
  CRT="$NODE_DIR/${NODE}.crt"
  P12="$NODE_DIR/keystore.p12"
  JKS="$NODE_DIR/keystore.jks"
  TS="$NODE_DIR/truststore.jks"
  CNF="$NODE_DIR/openssl.cnf"

  if [[ -f "$JKS" && -f "$TS" && "$FORCE" != "1" ]]; then
    echo "[OK] Node $NODE already has keystore/truststore. Skipping. (Set FORCE=1 to regen.)"
    continue
  fi

  if [[ "$FORCE" == "1" ]]; then
    echo "[WARN] FORCE=1: Regenerating materials for node $NODE"
    rm -f "$KEY" "$CSR" "$CRT" "$P12" "$JKS" "$TS" "$CNF"
  fi

  echo "[INFO] [$NODE] Generating OpenSSL config with SANs..."
  make_openssl_cnf "$NODE" "$CNF"

  echo "[INFO] [$NODE] Generating private key..."
  openssl genrsa -out "$KEY" 2048

  echo "[INFO] [$NODE] Creating CSR..."
  openssl req -new -key "$KEY" -out "$CSR" -config "$CNF"

  echo "[INFO] [$NODE] Signing cert with CA..."
  openssl x509 -req -in "$CSR" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$CRT" -days 825 -sha256 \
    -extensions req_ext -extfile "$CNF"

  echo "[INFO] [$NODE] Creating PKCS12 keystore..."
  openssl pkcs12 -export \
    -out "$P12" \
    -inkey "$KEY" \
    -in "$CRT" \
    -certfile "$CA_CRT" \
    -name "$NODE" \
    -passout "pass:${PW}"

  echo "[INFO] [$NODE] Converting PKCS12 -> JKS..."
  keytool -importkeystore \
    -srckeystore "$P12" -srcstoretype PKCS12 -srcstorepass "$PW" \
    -destkeystore "$JKS" -deststoretype JKS -deststorepass "$PW" \
    -destkeypass "$PW" \
    -alias "$NODE" >/dev/null

  echo "[INFO] [$NODE] Creating/updating truststore with CA..."
  # If alias exists, delete then re-import (keeps idempotency)
  if keytool -list -keystore "$TS" -storepass "$PW" -alias nifi-ca >/dev/null 2>&1; then
    keytool -delete -alias nifi-ca -keystore "$TS" -storepass "$PW" >/dev/null
  fi

  keytool -importcert -noprompt \
    -alias nifi-ca \
    -file "$CA_CRT" \
    -keystore "$TS" \
    -storepass "$PW" >/dev/null

  echo "[DONE] [$NODE] Generated:"
  echo "  - $JKS"
  echo "  - $TS"
done

echo "[DONE] All requested nodes processed."
