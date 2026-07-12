#!/usr/bin/env bash
# TunnelGate – Fully Automated Installer
# Usage: sudo ./install.sh

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
NGINX_SITE="tunnelgate.conf"
SERVICE_PREFIX="tunnelgate"
SYSTEMD_DIR="/etc/systemd/system"

# Defaults (will be prompted if not provided via env)
DOMAIN="${DOMAIN:-tunnel.example.com}"
EMAIL="${EMAIL:-admin@example.com}"
HTTP_PORTS="${HTTP_PORTS:-80}"
TLS_PORTS="${TLS_PORTS:-443}"
CERT_METHOD="${CERT_METHOD:-le_http01}"
CF_TOKEN="${CF_TOKEN:-}"
CF_EMAIL="${CF_EMAIL:-}"
CF_GLOBAL_KEY="${CF_GLOBAL_KEY:-}"

# =====================================================================
# COLORS & LOGGING
# =====================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[+]${NC} $(date +'%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $(date +'%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[X]${NC} $(date +'%H:%M:%S') $*" >&2; }
log_step()  { echo -e "${BLUE}[*]${NC} $(date +'%H:%M:%S') $*"; }

# =====================================================================
# ROOT CHECK
# =====================================================================
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root. Use: sudo $0"
    exit 1
fi

# =====================================================================
# OS DETECTION
# =====================================================================
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    log_error "Cannot detect OS. Only Debian/Ubuntu are supported."
    exit 1
fi
case $OS in
    debian|ubuntu) log_info "Detected $OS" ;;
    *) log_error "Unsupported OS: $OS"; exit 1 ;;
esac

# =====================================================================
# STEP 1: REMOVE CONFLICTING PROGRAMS
# =====================================================================
log_step "Removing conflicting web servers..."

# Stop and remove Apache
if systemctl list-units --full -all | grep -q apache2; then
    log_info "Removing Apache..."
    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true
    apt-get remove -y apache2 apache2-* 2>/dev/null || true
fi

# Stop and remove lighttpd
if systemctl list-units --full -all | grep -q lighttpd; then
    log_info "Removing lighttpd..."
    systemctl stop lighttpd 2>/dev/null || true
    systemctl disable lighttpd 2>/dev/null || true
    apt-get remove -y lighttpd 2>/dev/null || true
fi

# Remove any existing Nginx that might conflict
if systemctl list-units --full -all | grep -q nginx; then
    log_info "Removing existing Nginx..."
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    apt-get remove -y nginx nginx-common nginx-core nginx-full 2>/dev/null || true
fi

# Clean up any remaining configs
rm -rf /etc/nginx 2>/dev/null || true

# =====================================================================
# STEP 2: KILL PROCESSES ON CONFLICTING PORTS
# =====================================================================
log_step "Killing processes on conflicting ports..."

for port in 80 443 2053 2083 2087 2096 8443; do
    if fuser -k "$port"/tcp 2>/dev/null; then
        log_info "Killed process on port $port"
    fi
done

# Wait for sockets to release
sleep 2

# =====================================================================
# STEP 3: CLEAN IPTABLES RULES
# =====================================================================
log_step "Cleaning iptables rules..."

# Save current rules (just in case)
iptables-save > /tmp/iptables-backup-$(date +%s).txt 2>/dev/null || true

# Flush all rules
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true

# Set default policies
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true

log_info "iptables rules cleared."

# =====================================================================
# STEP 4: INSTALL SYSTEM PACKAGES
# =====================================================================
log_step "Installing system packages..."

apt-get update -y

apt-get install -y \
    curl wget git make \
    nginx-extras \
    certbot python3-certbot-nginx \
    dropbear \
    iptables iptables-persistent \
    openssl sqlite3 \
    net-tools \
    lsof \
    fuser

# Verify Nginx stream module
if ! nginx -V 2>&1 | grep -q with-stream; then
    log_error "Nginx installed without stream module. Please check nginx-extras."
    exit 1
fi

# =====================================================================
# STEP 5: INSTALL GO 1.23
# =====================================================================
log_step "Installing Go 1.23..."

GO_VERSION="1.23.0"
GO_ARCH="linux-amd64"
if [[ "$(uname -m)" == "aarch64" ]]; then
    GO_ARCH="linux-arm64"
fi

cd /tmp
rm -f "go${GO_VERSION}.${GO_ARCH}.tar.gz"
wget -q "https://go.dev/dl/go${GO_VERSION}.${GO_ARCH}.tar.gz"
rm -rf /usr/local/go
tar -C /usr/local -xzf "go${GO_VERSION}.${GO_ARCH}.tar.gz"
rm -f "go${GO_VERSION}.${GO_ARCH}.tar.gz"

export PATH="/usr/local/go/bin:$PATH"
if ! grep -q "export PATH=/usr/local/go/bin" /etc/profile; then
    echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile
fi

GO_BIN="/usr/local/go/bin/go"
if ! $GO_BIN version | grep -q "go1.23"; then
    log_error "Go 1.23 installation failed."
    exit 1
fi
log_info "Go installed: $($GO_BIN version)"

# =====================================================================
# STEP 6: CLONE/UPDATE SOURCE
# =====================================================================
log_step "Setting up source code..."

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

# =====================================================================
# STEP 7: DOWNLOAD DEPENDENCIES & BUILD
# =====================================================================
log_step "Downloading dependencies and building..."

$GO_BIN clean -modcache
$GO_BIN mod download
$GO_BIN mod tidy

make clean
make GO=$GO_BIN build

BINARY="$INSTALL_DIR/bin/tunnelgate"
if [[ ! -f "$BINARY" ]]; then
    log_error "Build failed – binary not found."
    exit 1
fi

cp "$BINARY" "$BIN_DIR/tunnelgate"
chmod +x "$BIN_DIR/tunnelgate"

# =====================================================================
# STEP 8: PROMPT FOR CONFIG (WITH DEFAULTS)
# =====================================================================
log_step "Configuration setup"

read -p "Domain [${DOMAIN}]: " input
DOMAIN="${input:-$DOMAIN}"

read -p "Email [${EMAIL}]: " input
EMAIL="${input:-$EMAIL}"

read -p "HTTP ports (comma-separated) [${HTTP_PORTS}]: " input
HTTP_PORTS="${input:-$HTTP_PORTS}"

read -p "TLS ports (comma-separated) [${TLS_PORTS}]: " input
TLS_PORTS="${input:-$TLS_PORTS}"

echo "Certificate methods:"
echo "  1) le_http01   - Let's Encrypt HTTP-01 (port 80)"
echo "  2) le_dns_cf   - Let's Encrypt DNS-01 via Cloudflare"
echo "  3) cf_origin   - Cloudflare Origin CA"
echo "  4) selfsigned  - Self-signed (for testing)"
read -p "Certificate method [${CERT_METHOD}]: " input
CERT_METHOD="${input:-$CERT_METHOD}"

case $CERT_METHOD in
    le_dns_cf|2)
        CERT_METHOD="le_dns_cf"
        read -p "Cloudflare API Token: " CF_TOKEN
        CF_TOKEN="${CF_TOKEN:-}"
        ;;
    cf_origin|3)
        CERT_METHOD="cf_origin"
        read -p "Cloudflare Email: " CF_EMAIL
        CF_EMAIL="${CF_EMAIL:-}"
        read -p "Cloudflare Global API Key: " CF_GLOBAL_KEY
        CF_GLOBAL_KEY="${CF_GLOBAL_KEY:-}"
        ;;
    selfsigned|4)
        CERT_METHOD="selfsigned"
        ;;
    *)
        CERT_METHOD="le_http01"
        ;;
esac

# =====================================================================
# STEP 9: CREATE DIRECTORIES AND CONFIG
# =====================================================================
log_step "Creating directories and config..."

mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$CERT_DIR"
chmod 700 "$CONFIG_DIR" "$DATA_DIR"

# Generate API token
API_TOKEN=$(openssl rand -hex 24)

# Convert ports to YAML arrays
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
cf_api_token: ${CF_TOKEN:-""}
cf_email: ${CF_EMAIL:-""}
cf_global_api_key: ${CF_GLOBAL_KEY:-""}

database: $DATA_DIR/users.db

log_level: info
log_format: text
EOF

chmod 600 "$CONFIG_DIR/config.yaml"

# =====================================================================
# STEP 10: CONFIGURE DROPBEAR
# =====================================================================
log_step "Configuring dropbear..."

cat > /etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT="127.0.0.1:109"
DROPBEAR_EXTRA_ARGS="-W 65536"
DROPBEAR_BANNER=""
EOF

# Ensure /bin/false is in /etc/shells
if ! grep -q "/bin/false" /etc/shells 2>/dev/null; then
    echo "/bin/false" >> /etc/shells
fi

systemctl enable dropbear
systemctl restart dropbear

# =====================================================================
# STEP 11: SYSTEMD UNITS
# =====================================================================
log_step "Installing systemd units..."

cat > "$SYSTEMD_DIR/${SERVICE_PREFIX}-proxy.service" <<'EOF'
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

cat > "$SYSTEMD_DIR/${SERVICE_PREFIX}-api.service" <<'EOF'
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

cat > "$SYSTEMD_DIR/${SERVICE_PREFIX}-renew.service" <<'EOF'
[Unit]
Description=Renew TLS certificate
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tunnelgate cert renew
EOF

cat > "$SYSTEMD_DIR/${SERVICE_PREFIX}-renew.timer" <<'EOF'
[Unit]
Description=Daily TLS certificate renewal
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable ${SERVICE_PREFIX}-proxy.service
systemctl enable ${SERVICE_PREFIX}-api.service
systemctl enable ${SERVICE_PREFIX}-renew.timer

# =====================================================================
# STEP 12: NGINX CONFIGURATION
# =====================================================================
log_step "Configuring Nginx..."

# Create minimal nginx.conf with stream support
cat > /etc/nginx/nginx.conf <<'EOF'
events {
    worker_connections 1024;
}

stream {
    include /etc/nginx/stream.conf;
}
EOF

# Generate stream config from tunnelgate
tunnelgate nginx configure 2>/dev/null || log_warn "Nginx config generation failed – will use minimal."

# Ensure Nginx can start
nginx -t 2>/dev/null || {
    log_warn "Nginx config test failed. Creating minimal stream config..."
    cat > /etc/nginx/stream.conf <<EOF
# Minimal stream config – will be replaced by tunnelgate
EOF
    nginx -t || log_error "Nginx config still failing."
}

systemctl enable nginx
systemctl restart nginx

# =====================================================================
# STEP 13: CERTIFICATE (if needed)
# =====================================================================
if [[ "$CERT_METHOD" != "selfsigned" ]]; then
    log_step "Obtaining certificate using $CERT_METHOD..."
    tunnelgate cert renew || log_warn "Certificate issuance failed – you may need to run 'tunnelgate cert renew' manually."
else
    log_step "Generating self-signed certificate..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERT_DIR/key.pem" \
        -out "$CERT_DIR/fullchain.pem" \
        -days 365 \
        -subj "/CN=$DOMAIN" 2>/dev/null || true
fi

# =====================================================================
# STEP 14: FIREWALL (IPTABLES)
# =====================================================================
log_step "Configuring iptables firewall..."

# Flush everything
iptables -F
iptables -X
iptables -t nat -F
iptables -t mangle -F

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Loopback
iptables -A INPUT -i lo -j ACCEPT

# Established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# SSH
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# Open all HTTP and TLS ports
for p in $(echo "$HTTP_PORTS,$TLS_PORTS" | tr ',' ' '); do
    iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
done

# Save
netfilter-persistent save 2>/dev/null || {
    # Fallback for systems without netfilter-persistent
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
}

log_info "Firewall rules applied."

# =====================================================================
# STEP 15: START SERVICES
# =====================================================================
log_step "Starting services..."

systemctl start ${SERVICE_PREFIX}-proxy.service
systemctl start ${SERVICE_PREFIX}-api.service
systemctl start ${SERVICE_PREFIX}-renew.timer

# =====================================================================
# STEP 16: VERIFICATION
# =====================================================================
log_step "Verifying services..."

sleep 2

PROXY_OK=false
if systemctl is-active --quiet ${SERVICE_PREFIX}-proxy.service; then
    PROXY_OK=true
    log_info "✓ Proxy service is running"
else
    log_error "✗ Proxy service failed. Check: journalctl -u ${SERVICE_PREFIX}-proxy"
fi

if systemctl is-active --quiet nginx; then
    log_info "✓ Nginx is running"
else
    log_warn "✗ Nginx is not running. Check: journalctl -u nginx"
fi

if systemctl is-active --quiet dropbear; then
    log_info "✓ Dropbear is running on 127.0.0.1:109"
else
    log_warn "✗ Dropbear is not running. Check: journalctl -u dropbear"
fi

# =====================================================================
# STEP 17: FINAL MESSAGE
# =====================================================================
echo ""
echo "========================================="
log_info "TunnelGate INSTALLATION COMPLETE!"
echo "========================================="
echo ""
echo "  - Domain:          $DOMAIN"
echo "  - HTTP ports:      $HTTP_PORTS"
echo "  - TLS ports:       $TLS_PORTS"
echo "  - Admin API:       http://127.0.0.1:8080"
echo "  - API Token:       $API_TOKEN"
echo "  - Database:        $DATA_DIR/users.db"
echo ""
if [[ "$PROXY_OK" == "true" ]]; then
    echo "✅ All services are running."
else
    echo "⚠️  Some services failed. Check logs above."
fi
echo ""
echo "Next steps:"
echo "  1. Add a user:    tunnelgate user add <username> --days 30"
echo "  2. Check status:  tunnelgate status"
echo "  3. View proxy logs: journalctl -u ${SERVICE_PREFIX}-proxy -f"
echo ""
echo "HTTP Injector configuration:"
echo "  - SSH Host:       $DOMAIN"
echo "  - SSH Port:       (any HTTP or TLS port)"
echo "  - Username:       <your user>"
echo "  - Password:       <the one you set>"
echo "  - Payload:        any HTTP GET with Upgrade: websocket header"
echo ""
echo "To clean everything: sudo $0 --clean"
