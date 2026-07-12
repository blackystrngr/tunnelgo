#!/usr/bin/env bash
# TunnelGate – All‑in‑one installer
# Usage: sudo ./install.sh              # normal install
#        sudo ./install.sh --clean      # remove everything EXCEPT certificates

set -euo pipefail

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------
REPO_URL="https://github.com/blackystrngr/tunnelgate.git"
INSTALL_DIR="/opt/tunnelgate"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/tunnelgate"
DATA_DIR="/var/lib/tunnelgate"
CERT_DIR="/etc/tunnelgate/certs"
NGINX_SITE="tunnelgate.conf"
SERVICE_PREFIX="tunnelgate"
SYSTEMD_DIR="/etc/systemd/system"

# ---------------------------------------------------------------------
# Colors and logging
# ---------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[+]${NC} $(date +'%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $(date +'%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[X]${NC} $(date +'%Y-%m-%d %H:%M:%S') $*" >&2; }
log_step()  { echo -e "${BLUE}[*]${NC} $(date +'%Y-%m-%d %H:%M:%S') $*"; }

# ---------------------------------------------------------------------
# Cleanup – preserves certificates
# ---------------------------------------------------------------------
cleanup_all() {
    log_warn "Performing cleanup (certificates in $CERT_DIR will be preserved)..."

    for svc in proxy api renew; do
        systemctl stop "${SERVICE_PREFIX}-${svc}.service" 2>/dev/null || true
        systemctl disable "${SERVICE_PREFIX}-${svc}.service" 2>/dev/null || true
    done
    systemctl stop "${SERVICE_PREFIX}-renew.timer" 2>/dev/null || true
    systemctl disable "${SERVICE_PREFIX}-renew.timer" 2>/dev/null || true

    rm -f "${SYSTEMD_DIR}/${SERVICE_PREFIX}-"*.service
    rm -f "${SYSTEMD_DIR}/${SERVICE_PREFIX}-"*.timer
    systemctl daemon-reload

    rm -f "${BIN_DIR}/tunnelgate"
    rm -rf "$CONFIG_DIR" "$DATA_DIR"
    log_info "Removed config and data, but preserved $CERT_DIR"

    rm -rf "$INSTALL_DIR"

    rm -f "/etc/nginx/sites-available/$NGINX_SITE"
    rm -f "/etc/nginx/sites-enabled/$NGINX_SITE"
    systemctl reload nginx 2>/dev/null || true

    log_info "Cleanup completed. Certificates remain in $CERT_DIR."
    log_info "To also remove certificates, manually delete: rm -rf $CERT_DIR"
}

trap 'log_error "Installation failed at step: $BASH_COMMAND"; exit 1' ERR

if [[ $# -gt 0 && "$1" == "--clean" ]]; then
    cleanup_all
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root. Use: sudo $0"
    exit 1
fi

# OS detection
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    log_error "Unsupported OS – only Debian/Ubuntu are supported."
    exit 1
fi
case $OS in
    debian|ubuntu) log_info "Detected $OS $VERSION" ;;
    *) log_error "Unsupported OS: $OS"; exit 1 ;;
esac

# ---------------------------------------------------------------------
# Install base packages (excluding go)
# ---------------------------------------------------------------------
log_step "Installing system packages..."
apt-get update -y
apt-get install -y \
    curl wget git make \
    nginx-extras certbot python3-certbot-nginx \
    dropbear iptables iptables-persistent \
    openssl sqlite3

if ! nginx -V 2>&1 | grep -q with-stream; then
    log_error "Nginx installed without stream module. Please install nginx-extras manually."
    exit 1
fi

# ---------------------------------------------------------------------
# Install Go 1.23 from official tarball
# ---------------------------------------------------------------------
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

# Set PATH for this session
export PATH="/usr/local/go/bin:$PATH"
# Also add to /etc/profile for future sessions
if ! grep -q "export PATH=/usr/local/go/bin" /etc/profile; then
    echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile
fi

log_info "Go installed: $(go version)"

# ---------------------------------------------------------------------
# Clone/update source (with forced reset)
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# Clean Go module cache and update dependencies
# ---------------------------------------------------------------------
log_step "Cleaning Go module cache and updating dependencies..."
go clean -modcache
go mod download
go mod tidy

# ---------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------
log_step "Building tunnelgate binary..."
make clean
make build

BINARY="$INSTALL_DIR/bin/tunnelgate"
if [[ ! -f "$BINARY" ]]; then
    log_error "Build failed – binary not found."
    exit 1
fi
cp "$BINARY" "$BIN_DIR/tunnelgate"
chmod +x "$BIN_DIR/tunnelgate"

# ---------------------------------------------------------------------
# Now ask for configuration (after successful build)
# ---------------------------------------------------------------------
log_step "Configuration setup"
read -p "Domain (e.g., tunnel.example.com): " DOMAIN
read -p "Email (for Let's Encrypt): " EMAIL
echo "Choose certificate method:"
echo "  1) Let's Encrypt HTTP-01 (port 80, standalone)"
echo "  2) Let's Encrypt DNS-01 via Cloudflare (requires API token)"
echo "  3) Cloudflare Origin CA (requires email + Global API Key)"
read -p "Choice (1/2/3): " CERT_CHOICE
case $CERT_CHOICE in
    1) CERT_METHOD="le_http01" ;;
    2) CERT_METHOD="le_dns_cf"
       read -p "Cloudflare API Token: " CF_TOKEN ;;
    3) CERT_METHOD="cf_origin"
       read -p "Cloudflare Email: " CF_EMAIL
       read -p "Cloudflare Global API Key: " CF_GLOBAL_KEY ;;
    *) log_error "Invalid choice"; exit 1 ;;
esac

read -p "HTTP ports (comma‑separated, e.g., 80,8080): " HTTP_PORTS_INPUT
read -p "TLS ports (comma‑separated, e.g., 443,8443): " TLS_PORTS_INPUT

# Convert to YAML arrays
HTTP_PORTS_YAML=$(echo "$HTTP_PORTS_INPUT" | sed 's/,/ /g' | xargs | sed 's/ /, /g')
TLS_PORTS_YAML=$(echo "$TLS_PORTS_INPUT" | sed 's/,/ /g' | xargs | sed 's/ /, /g')

# ---------------------------------------------------------------------
# Create directories and config
# ---------------------------------------------------------------------
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$CERT_DIR"
chmod 700 "$CONFIG_DIR" "$DATA_DIR"

if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
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
  token: "$(openssl rand -hex 24)"

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
fi

# ---------------------------------------------------------------------
# Systemd units
# ---------------------------------------------------------------------
log_step "Installing systemd units..."
cat > "$SYSTEMD_DIR/${SERVICE_PREFIX}-proxy.service" <<EOF
[Unit]
Description=TunnelGate Proxy Core
After=network.target

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

cat > "$SYSTEMD_DIR/${SERVICE_PREFIX}-api.service" <<EOF
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

cat > "$SYSTEMD_DIR/${SERVICE_PREFIX}-renew.service" <<EOF
[Unit]
Description=Renew TLS certificate
[Service]
Type=oneshot
ExecStart=/usr/local/bin/tunnelgate cert renew
EOF

cat > "$SYSTEMD_DIR/${SERVICE_PREFIX}-renew.timer" <<EOF
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

# ---------------------------------------------------------------------
# Nginx config
# ---------------------------------------------------------------------
log_step "Generating Nginx config..."
tunnelgate nginx configure 2>/dev/null || log_warn "Nginx config generation failed – you may need to run it manually."

# ---------------------------------------------------------------------
# Certificate (will reuse if valid)
# ---------------------------------------------------------------------
if [[ -n "$DOMAIN" ]]; then
    log_info "Checking/obtaining certificate for $DOMAIN using $CERT_METHOD..."
    tunnelgate cert renew || log_warn "Certificate issuance failed – check logs."
fi

# ---------------------------------------------------------------------
# Firewall (iptables)
# ---------------------------------------------------------------------
log_step "Configuring iptables firewall..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t mangle -F

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT   # SSH

# Open all HTTP and TLS ports
for p in $(echo "$HTTP_PORTS_INPUT,$TLS_PORTS_INPUT" | tr ',' ' '); do
    iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
done

netfilter-persistent save
log_info "Firewall rules applied and saved."

# ---------------------------------------------------------------------
# Start services
# ---------------------------------------------------------------------
log_step "Starting services..."
systemctl start ${SERVICE_PREFIX}-proxy.service
systemctl start ${SERVICE_PREFIX}-api.service
systemctl start ${SERVICE_PREFIX}-renew.timer

# ---------------------------------------------------------------------
# Final message
# ---------------------------------------------------------------------
echo ""
log_info "TunnelGate installation complete!"
echo ""
echo "  - Domain:          $DOMAIN"
echo "  - HTTP ports:      $HTTP_PORTS_INPUT"
echo "  - TLS ports:       $TLS_PORTS_INPUT"
echo "  - Admin API:       http://127.0.0.1:8080 (token in $CONFIG_DIR/config.yaml)"
echo "  - Database:        $DATA_DIR/users.db"
echo ""
echo "Next steps:"
echo "  1. Add a user:    tunnelgate user add <username> --days 30"
echo "  2. Check status:  tunnelgate status"
echo "  3. View logs:     journalctl -u ${SERVICE_PREFIX}-proxy -f"
echo ""
echo "Configure HTTP Injector with:"
echo "  - SSH Host:       $DOMAIN"
echo "  - SSH Port:       (any of the configured ports)"
echo "  - Username:       <your user>"
echo "  - Password:       <the one you set>"
echo "  - Payload:        any HTTP GET with or without Upgrade header."
echo ""
echo "To clean everything EXCEPT certificates, run: sudo $0 --clean"
