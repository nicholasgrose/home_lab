#!/bin/bash
# Styx Setup Script
# This script configures a Digital Ocean droplet as a proxy/bastion VPS
# for connecting to a home network via Wireguard and managing traffic with nginx-proxy-manager

set -e

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log "This script must be run as root"
    exit 1
fi

# Source environment variables if file exists
if [ -f /root/styx_env.sh ]; then
    log "Loading environment variables"
    source /root/styx_env.sh
else
    log "Environment file not found. Please create /root/styx_env.sh with required variables"
    exit 1
fi

# Check for required environment variables
required_vars=(
    "WG_PEER_PUBLIC_KEY"
    "WG_CLIENT_IP"
    "WG_ALLOWED_IPS"
    "DOMAIN_NAME"
    "NPM_ADMIN_EMAIL"
    "NPM_ADMIN_PASSWORD"
    "NPM_DATABASE_PASSWORD"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log "Error: Required environment variable $var is not set"
        exit 1
    fi
done

# ===== WIREGUARD SETUP =====
log "Setting up Wireguard"

# Generate Wireguard private key if not provided
if [ -z "$WG_PRIVATE_KEY" ]; then
    log "Generating Wireguard private key"
    WG_PRIVATE_KEY=$(wg genkey)
    # Update the environment file
    sed -i "s/export WG_PRIVATE_KEY=\"\"/export WG_PRIVATE_KEY=\"$WG_PRIVATE_KEY\"/g" /root/styx_env.sh
fi

# Create Wireguard configuration
log "Creating Wireguard configuration"
envsubst < /etc/wireguard/wg0.conf.template > /etc/wireguard/wg0.conf

# Enable and start Wireguard
log "Enabling Wireguard"
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# ===== PODMAN SETUP =====
log "Setting up Podman"

# Create podman network for nginx-proxy-manager
podman network exists npm-network || podman network create npm-network

# Create directories for nginx-proxy-manager
mkdir -p /opt/npm/data
mkdir -p /opt/npm/letsencrypt

# Create docker-compose.yml for nginx-proxy-manager
cat > /opt/npm/docker-compose.yml << EOF
version: '3'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    environment:
      DB_MYSQL_HOST: "db"
      DB_MYSQL_PORT: 3306
      DB_MYSQL_USER: "npm"
      DB_MYSQL_PASSWORD: "${NPM_DATABASE_PASSWORD}"
      DB_MYSQL_NAME: "npm"
    depends_on:
      - db

  db:
    image: 'jc21/mariadb-aria:latest'
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${NPM_DATABASE_PASSWORD}"
      MYSQL_DATABASE: "npm"
      MYSQL_USER: "npm"
      MYSQL_PASSWORD: "${NPM_DATABASE_PASSWORD}"
    volumes:
      - ./data/mysql:/var/lib/mysql
EOF

# Install podman-compose if not already installed
if ! command -v podman-compose &> /dev/null; then
    log "Installing podman-compose"
    pip3 install podman-compose
fi

# Start nginx-proxy-manager
log "Starting nginx-proxy-manager"
cd /opt/npm
podman-compose up -d

# ===== SYSTEM CONFIGURATION =====
log "Configuring system settings"

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ip-forward.conf
sysctl -p /etc/sysctl.d/99-ip-forward.conf

# Configure iptables for NAT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i wg0 -j ACCEPT
iptables -A FORWARD -o wg0 -j ACCEPT

# Save iptables rules
iptables-save > /etc/iptables/rules.v4

# Create systemd service for nginx-proxy-manager
cat > /etc/systemd/system/nginx-proxy-manager.service << EOF
[Unit]
Description=Nginx Proxy Manager
After=network.target podman.service
Requires=podman.service

[Service]
WorkingDirectory=/opt/npm
ExecStart=/usr/local/bin/podman-compose up
ExecStop=/usr/local/bin/podman-compose down
Type=simple
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable nginx-proxy-manager
systemctl start nginx-proxy-manager

# ===== FINAL SETUP =====
log "Performing final setup tasks"

# Create a script to update the default NPM credentials
cat > /opt/npm/update_credentials.sh << EOF
#!/bin/bash
# Wait for the API to be available
echo "Waiting for Nginx Proxy Manager API to be available..."
until curl -s http://localhost:81/api/tokens > /dev/null; do
    sleep 5
done

# Update the default credentials
curl -X PUT http://localhost:81/api/users/1 \
  -H "Content-Type: application/json" \
  -d '{
    "email": "${NPM_ADMIN_EMAIL}",
    "name": "Styx Admin",
    "nickname": "admin",
    "password": "${NPM_ADMIN_PASSWORD}",
    "roles": ["admin"]
  }'

echo "Credentials updated successfully!"
EOF

chmod +x /opt/npm/update_credentials.sh

# Run the credential update script in the background
nohup /opt/npm/update_credentials.sh > /opt/npm/update_credentials.log 2>&1 &

# Create a status file to indicate successful setup
touch /root/styx_setup_complete

log "Styx setup completed successfully!"
log "Nginx Proxy Manager is available at: http://${DOMAIN_NAME}:81"
log "Please allow a few minutes for all services to start properly."
