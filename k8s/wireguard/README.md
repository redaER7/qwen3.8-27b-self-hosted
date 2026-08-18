# WireGuard Setup

Shared WireGuard setup scripts for connecting a Hetzner CP node to one or more remote GPU nodes (e.g. Trooper AI).

## How it works

Flannel VXLAN (UDP 8472) is used for pod-to-pod networking across nodes. Both K3s server and agent must set `--flannel-iface=wg0` so VXLAN packets are sent through the WireGuard tunnel.

```
CP node (Hetzner)                GPU node (Trooper AI)
┌────────────────────┐          ┌──────────────────────────┐
│ wg0 (10.10.0.1) ───┼─ tunnel ─┼──→ wg0 (10.10.0.2)      │
│ K3s server         │ UDP 51820│   K3s agent              │
│ flannel-iface=wg0  │          │   flannel-iface=wg0      │
│ node-ip: 10.10.0.1 │          │   node-ip: 10.10.0.2     │
└────────────────────┘          └──────────────────────────┘
```

Both nodes need UFW rules allowing UDP 8472 from the peer's WG subnet:
```bash
sudo ufw allow from 10.10.0.0/24 to any port 8472 proto udp
```

## K3s requirements

**On the CP node** — K3s config at `/etc/rancher/k3s/config.yaml`:
```yaml
node-ip: 10.10.0.1
advertise-address: 10.10.0.1
node-external-ip: <public-ip>
flannel-iface: wg0
```

**On each GPU node** — K3s agent install:
```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.33.2+k3s1" \
  K3S_URL="https://10.10.0.1:6443" \
  K3S_TOKEN="<node-token>" \
  K3S_NODE_NAME="gpu-node-$(hostname)" \
  INSTALL_K3S_EXEC="agent --node-ip=10.10.0.2 --flannel-iface=wg0" sh -
```

## Setup

### 1. CP node (run first)

```bash
bash wireguard/cp-wireguard-setup.sh
```

- Generates server keys, creates `/etc/wireguard/wg0.conf`
- Configures K3s with `node-ip: 10.10.0.1`, `flannel-iface: wg0`
- Starts `wg-quick@wg0`
- Prints the **server public key** and **K3s join token**

### 2. Each GPU node

```bash
bash wireguard/gpu-wireguard-setup.sh
```

The script:
- Generates client keys
- Prompts for CP's public key and public IP
- Creates `/etc/wireguard/wg0.conf`, starts WireGuard
- Verifies tunnel with `ping 10.10.0.1`

Install K3s agent separately (see above).

### 3. Add GPU peer to CP config

On the CP, add each GPU's public key to `/etc/wireguard/wg0.conf`. Each GPU listens on its own WireGuard port (default `29817`), **not** `51820`, so include the GPU's public IP and port as the peer `Endpoint`:

```ini
[Peer]
PublicKey = <gpu-public-key>
AllowedIPs = 10.10.0.2/32
Endpoint = <GPU_PUBLIC_IP>:29817
```

Then restart: `sudo systemctl restart wg-quick@wg0`

### 4. Verify

```bash
# From GPU node
ping -c 3 10.10.0.1

# From CP node
ping -c 3 10.10.0.2

# Cross-node Flannel pod connectivity
kubectl run -it --rm debug --image=busybox --restart=Never -- ping -c 3 10.10.0.2
```

## Multi-GPU example

CP config with two GPU peers. Give each GPU a distinct listen port (within the Trooper AI allowed inbound range `29817–29836`) and match it in the peer `Endpoint`:

```ini
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = <cp-private-key>
MTU = 1420

[Peer]
# GPU 1 (wg0 ListenPort = 29817)
PublicKey = <gpu1-pub-key>
AllowedIPs = 10.10.0.2/32
Endpoint = <gpu1-public-ip>:29817

[Peer]
# GPU 2 (wg0 ListenPort = 29818)
PublicKey = <gpu2-pub-key>
AllowedIPs = 10.10.0.3/32
Endpoint = <gpu2-public-ip>:29818
```

## Firewall reference (both nodes)

### CP node (Hetzner) — UFW

| Port | Protocol | From | Purpose |
|------|----------|------|---------|
| 51820 | UDP | Anywhere | WireGuard tunnel |
| 8472 | UDP | 10.10.0.0/24 | Flannel VXLAN |
| 6443 | TCP | 10.10.0.0/24 | K3s API |
| 10250 | TCP | 10.10.0.0/24 | Kubelet |
| 22 | TCP | Anywhere | SSH |

### GPU node (Trooper AI) — UFW

| Port | Protocol | From | Purpose |
|------|----------|------|---------|
| 8472 | UDP | 10.10.0.0/24 | Flannel VXLAN |
| 22 | TCP | Anywhere | SSH |

### External firewall (Trooper AI GPU node)

Trooper AI has an external firewall in front of the GPU node. These rules must be configured in the Trooper AI dashboard **before** WireGuard can connect. The GPU node's WireGuard listen port must be inside the allowed inbound range (`29817–29836`), otherwise the CP's handshake replies are dropped:

| Port | Protocol | Destination | Direction | Purpose |
|------|----------|-------------|-----------|---------|
| 29817–29836 | UDP | <GPU_NODE_IP> | Inbound | WireGuard replies from CP (GPU listen port) |
| 29839 | TCP | <GPU_NODE_IP> | Inbound | SSH |
| 51820 | UDP | <CP_NODE_IP> | Outbound | WireGuard handshake/keepalive to CP |

## Troubleshooting

**Symptom** — `ping -c 3 10.10.0.2` from the CP returns `Destination Host Unreachable`, and on the GPU `sudo wg show wg0` shows `transfer: 0 B received, <n> B sent` (handshake replies never arrive).

**Cause** — the GPU node's WireGuard daemon picked an ephemeral listen port (e.g. `37460`) that is outside the Trooper AI allowed inbound range, so the CP's replies are dropped by the external firewall.

**Fix**

1. Pin the listen port to an allowed value in `/etc/wireguard/wg0.conf` on the GPU node:

   ```ini
   [Interface]
   Address = 10.10.0.2/24
   ListenPort = 29817
   ```

2. Restart the tunnel:
   ```bash
   sudo systemctl restart wg-quick@wg0
   ```

3. On the CP, set the peer `Endpoint = <GPU_PUBLIC_IP>:29817` and restart `wg-quick@wg0`.

4. Verify:
   ```bash
   # On the GPU node — received bytes should now grow
   sudo wg show wg0

   # On the CP node
   ping -c 3 10.10.0.2
   ```


## Files

| File | Purpose |
|------|---------|
| `cp-wireguard-setup.sh` | WireGuard + K3s config on CP node |
| `gpu-wireguard-setup.sh` | WireGuard setup on GPU node |
| `trooper-gpu-port-forward.sh` | Optional: kubelet port forwarding for Trooper AI |
