#!/usr/bin/env bash

set -euo pipefail

# Creates CA (Certificate Authority) once.
# Idempotent: if CA already exists, it won't overwrite unless FORCE=1.

PKI_DIR="${PKI_DIR:-./pki}"
CA_DIR="${CA_DIR:-$PKI_DIR/ca}"
DAYS="${DAYS:-3650}"
FORCE="${FORCE:-0}"

mkdir -p "$CA_DIR"

CA_KEY="$CA_DIR/ca.key"
CA_CRT="$CA_DIR/ca.crt"
CA_SRL="$CA_DIR/ca.srl"

if [[ -f "$CA_KEY" || -f "$CA_CRT" ]]; then
  if [[ "$FORCE" != "1" ]]; then
    echo "[OK] CA already exists at: $CA_DIR"
    echo "     (Set FORCE=1 to regenerate, but that will break existing nodes.)"
    exit 0
  fi
  echo "[WARN] FORCE=1 set. Regenerating CA (this invalidates old node/client certs)."
  rm -f "$CA_KEY" "$CA_CRT" "$CA_SRL"
fi

echo "[INFO] Generating CA key..."
openssl genrsa -out "$CA_KEY" 4096

echo "[INFO] Generating CA certificate..."
openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$DAYS" \
  -subj "/CN=NiFi-Local-CA" \
  -out "$CA_CRT"

echo "[DONE] CA created:"
echo "  - $CA_KEY"
echo "  - $CA_CRT"
