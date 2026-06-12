#!/bin/bash
# ==============================================================================
# Server setup script
# Target OS : Ubuntu (Debian-based)
# Run as    : root
# Behavior  : on error — ask user whether to retry, continue, or abort
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
log()  { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
err()  { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Script must be run as root."
    exit 1
  fi
}

on_error() {
  local cmd="$1"
  local line="$2"
  local code="$3"

  err "Command failed (exit $code) at line $line: $cmd"

  while true; do
    read -rp "  [r]etry  [c]ontinue  [a]bort ? " choice
    case "$choice" in
      r|R)
        log "Retrying: $cmd"
        eval "$cmd" && return 0
        err "Retry failed."
        ;;
      c|C)
        log "Continuing after error."
        return 0
        ;;
      a|A)
        err "Aborted by user."
        exit "$code"
        ;;
      *)
        echo "  Enter r, c, or a."
        ;;
    esac
  done
}

trap 'on_error "$BASH_COMMAND" "$LINENO" "$?"' ERR

require_root

# ------------------------------------------------------------------------------
# Interactive input collection (upfront, before execution)
# ------------------------------------------------------------------------------
echo ""
echo "=== Interactive parameters ==="
echo ""

# SECRET_KEY for remnanode
while true; do
  read -rp "remnanode SECRET_KEY (paste full value, no spaces): " REMNA_SECRET_KEY
  [[ -n "$REMNA_SECRET_KEY" ]] && break
  echo "  Value cannot be empty."
done

# SNI_DOMAIN for xray-sni
while true; do
  read -rp "xray-sni SNI_DOMAIN (e.g. example.com): " SNI_DOMAIN
  [[ -n "$SNI_DOMAIN" ]] && break
  echo "  Value cannot be empty."
done

# CF_API_TOKEN for xray-sni
while true; do
  read -rp "xray-sni CF_API_TOKEN: " CF_API_TOKEN
  [[ -n "$CF_API_TOKEN" ]] && break
  echo "  Value cannot be empty."
done

# Remnanode API IP
while true; do
  read -rp "IP for Remnanode API access (port 2222): " REMNA_API_IP
  [[ -n "$REMNA_API_IP" ]] && break
  echo "  Value cannot be empty."
done

# Metrics IP
while true; do
  read -rp "IP for Metrics access (ports 9100, 9200): " METRICS_IP
  [[ -n "$METRICS_IP" ]] && break
  echo "  Value cannot be empty."
done

# Копировать сертификат с существующей ноды?
while true; do
  read -rp "Copy cert from existing node in this group? (y/n): " COPY_CERT
  [[ "$COPY_CERT" =~ ^[yn]$ ]] && break
  echo "  Enter y or n."
done

if [[ "$COPY_CERT" == "y" ]]; then
  while true; do
    read -rp "IP of existing node with this SNI_DOMAIN: " CERT_SOURCE_IP
    [[ -n "$CERT_SOURCE_IP" ]] && break
    echo "  Value cannot be empty."
  done
else
  CERT_SOURCE_IP=""
fi

echo ""
log "All parameters collected. Starting setup."
echo ""

# ==============================================================================
# 1. System update & base packages
# ==============================================================================
log "=== 1/11  System update & base packages ==="
apt update && apt upgrade -y
apt install -y mc htop btop iftop curl wget

# ==============================================================================
# 2. Timezone
# ==============================================================================
log "=== 2/11  Timezone ==="
timedatectl set-timezone Europe/Moscow
timedatectl

# ==============================================================================
# 3. Docker
# ==============================================================================
log "=== 3/11  Docker ==="
curl -fsSL https://get.docker.com | sh

# ==============================================================================
# 4. Kernel parameters (sysctl)
# nf_conntrack module must be loaded before sysctl -p,
# because net.netfilter.nf_conntrack_max requires it.
# ==============================================================================
log "=== 4/11  Kernel parameters ==="

modprobe nf_conntrack
echo "nf_conntrack" >> /etc/modules-load.d/conntrack.conf

cat >> /etc/sysctl.conf << 'EOF'

# VPN Optimization
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.netfilter.nf_conntrack_max = 262144
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl -p

# ==============================================================================
# 5. File descriptor limits
# ==============================================================================
log "=== 5/11  File descriptor limits ==="

cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 300000
* hard nofile 300000
root soft nofile 300000
root hard nofile 300000
EOF

mkdir -p /etc/systemd/system.conf.d/
cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=300000
EOF

systemctl daemon-reload

# ==============================================================================
# 6. UFW firewall
# ==============================================================================
log "=== 6/11  UFW ==="
apt install -y ufw

# Allow
ufw allow 22/tcp comment 'SSH'
ufw allow 443/tcp comment 'VLESS Reality'
ufw allow from "${REMNA_API_IP}" to any port 2222 proto tcp comment 'Remnanode API'
ufw allow from "${METRICS_IP}" to any port 9100 proto tcp comment 'Node Metrics'
ufw allow from "${METRICS_IP}" to any port 9200 proto tcp comment 'Speedtest Metrics'

# Deny inbound — abuse/scanner networks
ufw deny from 178.162.203.0/24
ufw deny from 45.159.79.0/24
ufw deny from 85.17.155.0/24
ufw deny from 185.221.222.0/24
ufw deny from 89.150.57.0/24
ufw deny from 46.165.199.0/24
ufw deny from 178.162.202.0/24
ufw deny from 85.17.70.0/24
ufw deny from 64.62.203.0/24

# Deny outbound — same networks + SMTP
ufw deny out to 178.162.203.0/24
ufw deny out to 45.159.79.0/24
ufw deny out to 85.17.155.0/24
ufw deny out to 185.221.222.0/24
ufw deny out to 89.150.57.0/24
ufw deny out to 46.165.199.0/24
ufw deny out to 178.162.202.0/24
ufw deny out to 85.17.70.0/24
ufw deny out to 64.62.203.0/24
ufw deny out 25

ufw --force enable
ufw status

# ==============================================================================
# 7. Fail2ban
# ==============================================================================
log "=== 7/11  Fail2ban ==="
apt install -y fail2ban
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl restart fail2ban
systemctl status fail2ban --no-pager

# ==============================================================================
# 8. Remnanode (Docker Compose)
# ==============================================================================
log "=== 8/11  Remnanode ==="

mkdir -p /opt/remnanode
mkdir -p /var/log/remnanode

cat > /opt/remnanode/docker-compose.yml << COMPOSE
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=${REMNA_SECRET_KEY}
    volumes:
      - /var/log/remnanode:/var/log/remnanode
COMPOSE

cd /opt/remnanode
docker compose up -d
log "Remnanode container status:"
docker compose ps

# ==============================================================================
# 9. Node Exporter
# ==============================================================================
log "=== 9/11  Node Exporter ==="

NODE_EXPORTER_VERSION="1.8.2"
cd /tmp

wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
tar xf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" \
       "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

if ! id node_exporter &>/dev/null; then
  useradd -rs /bin/false node_exporter
fi

tee /etc/systemd/system/node_exporter.service > /dev/null << 'EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter
systemctl status node_exporter --no-pager

# ==============================================================================
# 10. Speedtest Exporter (Docker Compose)
# ==============================================================================
log "=== 10/11  Speedtest Exporter ==="

mkdir -p /root/speedtest-exporter

cat > /root/speedtest-exporter/docker-compose.yml << 'COMPOSE'
services:
  speedtest-exporter:
    image: kutovoys/speedtest-exporter
    environment:
      - SERVER_IDS=32983
      - UPDATE_INTERVAL=60
      - METRICS_PROTECTED=false
      - METRICS_USERNAME=custom_user
      - METRICS_PASSWORD=custom_password
    ports:
      - "9200:9090"
COMPOSE

cd /root/speedtest-exporter
docker compose up -d
log "Speedtest exporter status:"
docker compose ps

# ==============================================================================
# 11. Logrotate for remnanode
# ==============================================================================
log "=== 11/11  Logrotate ==="
apt install -y logrotate

cat > /etc/logrotate.d/remnanode << 'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

logrotate -vf /etc/logrotate.d/remnanode

# ==============================================================================
# Post-install: xray-sni
# ==============================================================================
log "=== Post-install  xray-sni ==="

cd /root
git clone https://github.com/locklance/xray-sni.git

cat > /root/xray-sni/.env << EOF
SNI_DOMAIN="${SNI_DOMAIN}"
SNI_PORT="9443"
CF_API_TOKEN="${CF_API_TOKEN}"
EOF

if [[ "${COPY_CERT}" == "y" ]]; then
  log "Copying certificate from ${CERT_SOURCE_IP}..."

  CERT_SRC_PATH="/var/lib/docker/volumes/xray-sni_caddy_data/_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${SNI_DOMAIN}"
  CERT_DST_PATH="/var/lib/docker/volumes/xray-sni_caddy_data/_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${SNI_DOMAIN}"

  cd /root/xray-sni
  docker compose up -d
  sleep 3
  docker compose down

  mkdir -p "$CERT_DST_PATH"

  scp -o StrictHostKeyChecking=no \
    "root@${CERT_SOURCE_IP}:${CERT_SRC_PATH}/${SNI_DOMAIN}.crt" \
    "${CERT_DST_PATH}/"

  scp -o StrictHostKeyChecking=no \
    "root@${CERT_SOURCE_IP}:${CERT_SRC_PATH}/${SNI_DOMAIN}.key" \
    "${CERT_DST_PATH}/"

  scp -o StrictHostKeyChecking=no \
    "root@${CERT_SOURCE_IP}:${CERT_SRC_PATH}/${SNI_DOMAIN}.json" \
    "${CERT_DST_PATH}/" 2>/dev/null || true

  log "Certificate copied from ${CERT_SOURCE_IP}. Caddy will use existing cert on start."
else
  log "New domain — Caddy will request certificate via DNS-01 on start."
fi

log "xray-sni cloned to /root/xray-sni. .env written. Start service manually: cd /root/xray-sni && docker compose up -d"

# ==============================================================================
log "=== Setup complete ==="
