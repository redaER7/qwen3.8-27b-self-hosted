#!/bin/bash

# Enable IP forwarding if not already
sudo sysctl -w net.ipv4.ip_forward=1

# set Internal IP of GPU node
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml <<EOF
node-ip: 10.10.0.2
flannel-iface: wg0
EOF
sudo systemctl restart k3s-agent


#open UFW Flannel VXLAN uses UDP 8472 for pod-to-pod networking across nodes
sudo systemctl start ufw
sudo ufw enable
sudo ufw allow from 10.10.0.0/24 to any port 8472 proto udp
sudo ufw allow 22/tcp
