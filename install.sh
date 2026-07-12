#!/usr/bin/env bash
# TunnelGate – Installer (uses standard apt Nginx from OS repo)
# Usage: sudo ./install.sh [--clean]

set -euo pipefail

# =====================================================================
# CONFIGURATION
# =====================================================================
REPO_URL="https://github.com/blackystrngr/tunnelgate.git"
INSTALL_DIR="/opt/tunnelgate"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/tunnelgate"
DATA_DIR="/var/lib/tunnelgate"
CERT_DIR="/etc/tunnelgate/certs"
SERVICE_PREFIX="tunnelgate"

# Defaults
DOMAIN="${DOMAIN:-tunnel.example.com}"
EMAIL="${EMAIL:-admin@example.com}"
HTTP_PORTS="${HTTP_PORTS:-80}"
TLS_PORTS="${TLS_PORTS:-443}"
CERT_METHOD="${CERT_METHOD:-selfsigned}"

# =====================================================================
# COLORS
# =====================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[+]${NC} $(date +'%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $(date +'%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[X]${NC} $(date +'%H:%M:%S') $*" >&2; }
log_step()  { echo -e "${BLUE}[*]${NC} $(date +'%H:%M:%S') $*"; }

# =====================================================================
# ROOT CHECK & CLEANUP
# =====================================================================
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root. Use: sudo $0"
    exit 1
fi

if [[ $# -gt 0 && "$1" == "--clean" ]]; then
    log_warn "Cleaning TunnelGate (certificates preserved)..."
    systemctl stop nginx tunnelgate-* 2>/dev/null || true
    systemctl disable nginx tunnelgate-* 2>/dev/null || true
    rm -f /etc/systemd/system/tunnelgate-*.{service,timer}
    systemctl daemon-reload
    rm -f /usr/local/bin/tunnelgate
    rm -rf /etc/tunnelgate /var/lib/tunnelgate /opt/tunnelgate
    rm -f /etc/nginx/sites-{available,enabled}/tunnelgate.conf
    rm -f /etc/nginx/stream.conf
    systemctl restart nginx 2>/dev/null || true
    log_info "Cleanup done. Certificates remain in $CERT_DIR."
    exit 0
fi

# =====================================================================
# OS DETECTION
# =====================================================================
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    log_error "Cannot detect OS."
    exit 1
fi
case $OS in
    debian|ubuntu) log_info "Detected $OS" ;;
    *) log_error "Unsupported OS: $OS"; exit 1 ;;
esac

# =====================================================================
# INSTALL DEPENDENCIES (including Nginx from apt)
# =====================================================================
log_step "Updating package lists..."
apt-get update -y

log_step "Installing Nginx and other dependencies..."
apt-get install -y \
    curl wget git make \
    nginx-extras \
    certbot python3-certbot-nginx \
    dropbear \
    iptables iptables-persistent \
    openssl sqlite3 \
    net-tools lsof

# Verify Nginx stream module
if ! nginx -V 2>&1 | grep -q with-stream; then
    log_error "Nginx stream module missing. Please install nginx-extras manually."
    exit 1
fi

# =====================================================================
# ENSURE NGINX CONFIG DIRS EXIST
# =====================================================================
mkdir -p /etc/nginx /etc/nginx/sites-available /etc/nginx/sites-enabled

# If nginx.conf doesn't exist, create minimal
if [[ ! -f /etc/nginx/nginx.conf ]]; then
    log_info "Creating minimal nginx.conf..."
    cat > /etc/nginx/nginx.conf <<'EOF'
events {
    worker_connections 1024;
}

stream {
    include /etc/nginx/stream.conf;
}
EOF
fi

# =====================================================================
# INSTALL GO
# =====================================================================
log_step "Installing Go 1.23..."
GO_VERSION="1.23.0"
GO_ARCH="linux-amd64"
[[ "$(uname -m)" == "aarch64" ]] && GO_ARCH="linux-arm64"

cd /tmp
wget -q "https://go.dev/dl/go${GO_VERSION}.${GO_ARCH}.tar.gz"
rm -rf /usr/local/go
tar -C /usr/local -xzf "go${GO_VERSION}.${GO_ARCH}.tar.gz"
rm -f "go${GO_VERSION}.${GO_ARCH}.tar.gz"

export PATH="/usr/local/go/bin:$PATH"
grep -q "export PATH=/usr/local/go/bin" /etc/profile || \
    echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile

GO_BIN="/usr/local/go/bin/go"
if ! $GO_BIN version | grep -q "go1.23"; then
    log_error "Go installation failed."
    exit 1
fi
log_info "Go installed: $($GO_BIN version)"

# =====================================================================
# CLONE & BUILD
# =====================================================================
log_step "Cloning/building TunnelGate..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
    cd "$INSTALL_DIR"
    git fetch origin
    git reset --hard origin/main
    git clean -f -d
else
    rm -rf "$INSTALL_DIR"
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

$GO_BIN clean -modcache
$GO_BIN mod download
$GO_BIN mod tidy
make clean
make GO=$GO_BIN build

BINARY="$INSTALL_DIR/bin/tunnelgate"
if [[ ! -f "$BINARY" ]]; then
    log_error "Build failed."
    exit 1
fi
cp "$BINARY" "$BIN_DIR/tunnelgate"
chmod +x "$BIN_DIR/tunnelgate"

# =====================================================================
# PROMPT FOR CONFIG
# =====================================================================
log_step "Configuration setup"
read -p "Domain [${DOMAIN}]: " input; DOMAIN="${input:-$DOMAIN}"
read -p "Email [${EMAIL}]: " input; EMAIL="${input:-$EMAIL}"
read -p "HTTP ports (comma) [${HTTP_PORTS}]: " input; HTTP_PORTS="${input:-$HTTP_PORTS}"
read -p "TLS ports (comma) [${TLS_PORTS}]: " input; TLS_PORTS="${input:-$TLS_PORTS}"

echo "Certificate methods:"
echo "  1) le_http01   - Let's Encrypt HTTP-01 (port 80)"
echo "  2) le_dns_cf   - Let's Encrypt DNS-01 via Cloudflare"
echo "  3) cf_origin   - Cloudflare Origin CA"
echo "  4) selfsigned  - Self-signed (for testing)"
read -p "Method [${CERT_METHOD}]: " input; CERT_METHOD="${input:-$CERT_METHOD}"

case $CERT_METHOD in
    le_dns_cf|2) CERT_METHOD="le_dns_cf"; read -p "Cloudflare API Token: " CF_TOKEN; CF_TOKEN="${CF_TOKEN:-}" ;;
    cf_origin|3) CERT_METHOD="cf_origin"; read -p "Cloudflare Email: " CF_EMAIL; CF_EMAIL="${CF_EMAIL:-}"; read -p "Cloudflare Global API Key: " CF_GLOBAL_KEY; CF_GLOBAL_KEY="${CF_GLOBAL_KEY:-}" ;;
    selfsigned|4) CERT_METHOD="selfsigned" ;;
    *) CERT_METHOD="le_http01" ;;
esac

# =====================================================================
# CREATE CONFIG
# =====================================================================
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$CERT_DIR"
chmod 700 "$CONFIG_DIR" "$DATA_DIR"

API_TOKEN=$(openssl rand -hex 24)
HTTP_PORTS_YAML=$(echo "$HTTP_PORTS" | sed 's/,/ /g' | xargs | sed 's/ /, /g')
TLS_PORTS_YAML=$(echo "$TLS_PORTS" | sed 's/,/ /g' | xargs | sed 's/ /, /g')

cat > "$CONFIG_DIR/config.yaml" <<EOF
domain: $DOMAIN
email: $EMAIL
backend_host: 127.0.0.1
backend_port: 109
proxy:
  listen_host: 127.0.0.1
  listen_port: 8888
  idle_timeout_seconds: 180
  shared_pass: ""
api:
  listen_host: 127.0.0.1
  listen_port: 8080
  token: "$API_TOKEN"
nginx:
  http_ports: [$HTTP_PORTS_YAML]
  tls_ports: [$TLS_PORTS_YAML]
cert_method: $CERT_METHOD
cert_path: $CERT_DIR/fullchain.pem
key_path: $CERT_DIR/key.pem
cf_api_token: ${CF_TOKEN:-""}
cf_email: ${CF_EMAIL:-""}
cf_global_api_key: ${CF_GLOBAL_KEY:-""}
database: $DATA_DIR/users.db
log_level: info
log_format: text
EOF
chmod 600 "$CONFIG_DIR/config.yaml"

# =====================================================================
# DROPBEAR
# =====================================================================
log_step "Configuring dropbear..."
cat > /etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT="127.0.0.1:109"
DROPBEAR_EXTRA_ARGS="-W 65536"
DROPBEAR_BANNER=""
EOF
grep -q "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells
systemctl enable dropbear
systemctl restart dropbear

# =====================================================================
# SYSTEMD UNITS
# =====================================================================
log_step "Installing systemd units..."
cat > /etc/systemd/system/tunnelgate-proxy.service <<'EOF'
[Unit]
Description=TunnelGate Proxy Core
After=network.target dropbear.service
Requires=dropbear.service
[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/tunnelgate start
Restart=always
RestartSec=5
PrivateTmp=true
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/tunnelgate-api.service <<'EOF'
[Unit]
Description=TunnelGate Admin API
After=network.target
[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/tunnelgate api
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/tunnelgate-renew.service <<'EOF'
[Unit]
Description=Renew TLS certificate
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tunnelgate cert renew
EOF

cat > /etc/systemd/system/tunnelgate-renew.timer <<'EOF'
[Unit]
Description=Daily TLS certificate renewal
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable tunnelgate-proxy tunnelgate-api tunnelgate-renew.timer

# =====================================================================
# CERTIFICATE
# =====================================================================
if [[ "$CERT_METHOD" == "selfsigned" ]]; then
    log_step "Generating self‑signed certificate..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERT_DIR/key.pem" \
        -out "$CERT_DIR/fullchain.pem" \
        -days 365 \
        -subj "/CN=$DOMAIN" 2>/dev/null
else
    log_step "Obtaining certificate using $CERT_METHOD..."
    tunnelgate cert renew || log_warn "Certificate issuance failed – you can run 'tunnelgate cert renew' later."
fi
chmod 600 "$CERT_DIR/"*.pem 2>/dev/null || true

# =====================================================================
# NGINX CONFIGURATION
# =====================================================================
log_step "Configuring Nginx..."

# Ensure nginx.conf has stream include
if ! grep -q "stream {" /etc/nginx/nginx.conf; then
    log_info "Adding stream block to nginx.conf..."
    echo "stream {" >> /etc/nginx/nginx.conf
    echo "    include /etc/nginx/stream.conf;" >> /etc/nginx/nginx.conf
    echo "}" >> /etc/nginx/nginx.conf
fi

# Generate stream config using tunnelgate
tunnelgate nginx configure 2>/dev/null || {
    log_warn "Failed to generate Nginx stream config – creating minimal."
    cat > /etc/nginx/stream.conf <<EOF
# Generated by TunnelGate
server {
    listen 443 ssl;
    proxy_pass 127.0.0.1:443;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
}
EOF
}

# Test and restart nginx
if nginx -t 2>/dev/null; then
    systemctl enable nginx
    systemctl restart nginx
    log_info "Nginx started successfully."
else
    log_warn "Nginx config test failed. Check: nginx -t"
fi

# =====================================================================
# FIREWALL
# =====================================================================
log_step "Configuring iptables..."
iptables -F; iptables -X; iptables -t nat -F; iptables -t mangle -F
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
for p in $(echo "$HTTP_PORTS,$TLS_PORTS" | tr ',' ' '); do
    iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
done
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
fi
log_info "Firewall rules applied."

# =====================================================================
# START SERVICES
# =====================================================================
log_step "Starting services..."
systemctl start tunnelgate-proxy tunnelgate-api tunnelgate-renew.timer

# =====================================================================
# VERIFICATION
# =====================================================================
sleep 2
PROXY_OK=false
systemctl is-active --quiet tunnelgate-proxy && PROXY_OK=true

# =====================================================================
# FINAL MESSAGE
# =====================================================================
echo ""
log_info "TunnelGate installation complete!"
echo "  Domain:          $DOMAIN"
echo "  HTTP ports:      $HTTP_PORTS"
echo "  TLS ports:       $TLS_PORTS"
echo "  API Token:       $API_TOKEN"
echo "  Database:        $DATA_DIR/users.db"
echo "  Nginx version:   $(nginx -v 2>&1 | awk -F/ '{print $2}' | awk '{print $1}')"
[[ "$PROXY_OK" == "true" ]] && echo "✅ Proxy is running." || echo "⚠️  Proxy failed – check journalctl -u tunnelgate-proxy"
echo ""
echo "Next: tunnelgate user add <username> --days 30"
echo "Clean: sudo $0 --clean"
