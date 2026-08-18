#!/usr/bin/env bash
set -euo pipefail

# socat forwarder: port 443 → Envoy Gateway NodePort 30080
#
# Envoy proxy runs as a NodePort service on 30080 (not 443).
# socat listens on 443 and forwards raw TCP to 127.0.0.1:30080.
# TLS handshake (SNI) passes through intact — Envoy terminates TLS.
#
# Run ONCE on the Hetzner CP node after k8s_deploy.sh.
# Works for case_FP8 (same NodePort).

SERVICE_NAME="envoy-443-forwarder"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "=== socat port 443 → 30080 forwarder ==="

echo "[1/4] Installing socat..."
sudo apt-get update -qq
sudo apt-get install -y -qq socat

echo "[2/4] Creating systemd service..."
sudo tee "$SERVICE_FILE" > /dev/null <<'EOF'
[Unit]
Description=Forward port 443 to Envoy Gateway NodePort 30080
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:443,reuseaddr,fork TCP:127.0.0.1:30080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "[3/4] Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE_NAME"

echo "[4/4] Verifying..."
sleep 2
sudo systemctl status "$SERVICE_NAME" --no-pager
echo ""
echo "Testing TCP connectivity..."
nc -zv 127.0.0.1 443

echo ""
echo "=== Done ==="
echo "Port 443 forwards to Envoy Gateway at 127.0.0.1:30080."
echo "Verify with:"
echo "  curl -k https://llm.yacodata.com/v1/chat/completions ..."
