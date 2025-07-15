#!/bin/bash
# Styx Setup Script
# This script configures a Digital Ocean droplet as a proxy/bastion VPS
# for connecting to a home network via Wireguard and managing traffic with nginx-proxy-manager

# Exit on error, but also trap the exit to provide more information
set -e

# Trap errors for better debugging
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR

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

# Check if WireGuard is already configured and running
if systemctl is-active --quiet wg-quick@wg0; then
    log "WireGuard is already running. Checking configuration..."

    # Check if we need to update the configuration
    if [ -f /etc/wireguard/wg0.conf ] && grep -q "${WG_PEER_PUBLIC_KEY}" /etc/wireguard/wg0.conf; then
        log "WireGuard configuration appears to be up to date. Skipping setup."
        SKIP_WG_SETUP=true
    else
        log "WireGuard configuration needs to be updated."
        SKIP_WG_SETUP=false
    fi
else
    log "WireGuard is not running. Proceeding with setup..."
    SKIP_WG_SETUP=false
fi

# Only proceed with WireGuard setup if needed
if [ "$SKIP_WG_SETUP" = false ]; then
    # Generate Wireguard private key if not provided
    if [ -z "$WG_PRIVATE_KEY" ]; then
        log "Generating Wireguard private key"
        WG_PRIVATE_KEY=$(wg genkey)
        # Update the environment file
        sed -i "s/export WG_PRIVATE_KEY=\"\"/export WG_PRIVATE_KEY=\"$WG_PRIVATE_KEY\"/g" /root/styx_env.sh
        log "WireGuard private key generated and saved to environment file"
    fi

    # Create Wireguard configuration
    log "Creating Wireguard configuration"
    envsubst < /etc/wireguard/wg0.conf.template > /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    log "WireGuard configuration created with proper permissions"

    # Enable and start/restart Wireguard
    log "Enabling and starting WireGuard"
    systemctl enable wg-quick@wg0
    if systemctl is-active --quiet wg-quick@wg0; then
        log "Restarting WireGuard to apply new configuration"
        systemctl restart wg-quick@wg0
    else
        log "Starting WireGuard for the first time"
        systemctl start wg-quick@wg0
    fi
fi

# ===== PODMAN SETUP =====
log "Setting up Podman"

# Check if Podman is installed
if ! command -v podman &> /dev/null; then
    log "ERROR: Podman is not installed. Please install it first."
    exit 1
fi

# Create podman network for nginx-proxy-manager if it doesn't exist
if ! podman network exists npm-network; then
    log "Creating Podman network 'npm-network'"
    podman network create npm-network
else
    log "Podman network 'npm-network' already exists"
fi

# Create directories for nginx-proxy-manager
log "Creating directories for Nginx Proxy Manager"
mkdir -p /opt/npm/data
mkdir -p /opt/npm/letsencrypt

# Check if docker-compose.yml already exists and if it needs updating
COMPOSE_FILE_UPDATED=false
if [ -f /opt/npm/docker-compose.yml ]; then
    log "docker-compose.yml already exists, checking if it needs updating"

    # Check if the current password in the file matches the environment variable
    if grep -q "DB_MYSQL_PASSWORD: \"${NPM_DATABASE_PASSWORD}\"" /opt/npm/docker-compose.yml; then
        log "docker-compose.yml appears to be up to date"
    else
        log "docker-compose.yml needs to be updated with new database password"
        COMPOSE_FILE_UPDATED=true
    fi
else
    log "Creating new docker-compose.yml"
    COMPOSE_FILE_UPDATED=true
fi

# Create or update docker-compose.yml if needed
if [ "$COMPOSE_FILE_UPDATED" = true ]; then
    log "Writing docker-compose.yml with current configuration"
    cat > /opt/npm/docker-compose.yml << EOF
services:
  nginx:
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
      INITIAL_ADMIN_EMAIL: "${NPM_ADMIN_EMAIL}"
      INITIAL_ADMIN_EMAIL: "${NPM_ADMIN_PASSWORD}"
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
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - ./data/mysql:/var/lib/mysql
EOF
    log "docker-compose.yml created/updated successfully"
fi

# Install podman-compose if not already installed
if ! command -v podman-compose &> /dev/null; then
    log "Installing podman-compose"
    pip3 install podman-compose

    # Verify installation
    if ! command -v podman-compose &> /dev/null; then
        log "ERROR: Failed to install podman-compose. Please install it manually."
        exit 1
    else
        log "podman-compose installed successfully"
    fi
else
    log "podman-compose is already installed"
fi

# Check if containers are already running
if podman ps | grep -q "nginx-proxy-manager"; then
    log "Nginx Proxy Manager is already running"

    # If compose file was updated, restart the containers
    if [ "$COMPOSE_FILE_UPDATED" = true ]; then
        log "Configuration was updated, restarting containers"
        cd /opt/npm
        podman-compose down
        podman-compose up -d
        log "Containers restarted with new configuration"
    fi
else
    # Start nginx-proxy-manager
    log "Starting Nginx Proxy Manager for the first time"
    cd /opt/npm
    podman-compose up -d

    # Verify containers started
    if podman ps | grep -q "nginx-proxy-manager"; then
        log "Nginx Proxy Manager started successfully"
    else
        log "ERROR: Failed to start Nginx Proxy Manager. Check logs with 'podman logs'"
    fi
fi

# ===== SYSTEM CONFIGURATION =====
log "Configuring system settings"

# Configure system-wide IP forwarding
cat > /etc/sysctl.d/99-ip-forward.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p /etc/sysctl.d/99-ip-forward.conf

# Configure UFW NAT and forwarding
cat >> /etc/ufw/before.rules << EOF

# NAT table rules
*nat
:POSTROUTING ACCEPT [0:0]
:PREROUTING ACCEPT [0:0]

# Forward traffic only from WireGuard subnet through eth0
-A POSTROUTING -s ${WG_ALLOWED_IPS} -o eth0 -j MASQUERADE

COMMIT

# Filter table rules for WireGuard
*filter
:ufw-before-input ACCEPT [0:0]
:ufw-before-output ACCEPT [0:0]
:ufw-before-forward ACCEPT [0:0]

# Forward only WireGuard traffic
-A ufw-before-forward -i wg0 -j ACCEPT
-A ufw-before-forward -o wg0 -j ACCEPT

# Ensure VPN traffic is allowed
-A ufw-before-input -i wg0 -j ACCEPT
-A ufw-before-output -o wg0 -j ACCEPT

COMMIT
EOF

# Keep UFW's default forward policy as DROP
if grep -q "DEFAULT_FORWARD_POLICY" /etc/default/ufw; then
    # Update existing policy
    sed -i 's/DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw
else
    # Add policy if it doesn't exist
    echo 'DEFAULT_FORWARD_POLICY="DROP"' >> /etc/default/ufw
fi

# Reload UFW to apply changes
ufw reload

# Create systemd service for nginx-proxy-manager
log "Setting up systemd service for Nginx Proxy Manager"

# Check if service file already exists
SERVICE_FILE_UPDATED=false
if [ -f /etc/systemd/system/nginx-proxy-manager.service ]; then
    log "Service file already exists, checking if it needs updating"

    # Check if the service file contains the correct ExecStart path
    if grep -q "ExecStart=/usr/local/bin/podman-compose up" /etc/systemd/system/nginx-proxy-manager.service; then
        log "Service file appears to be up to date"
    else
        log "Service file needs to be updated"
        SERVICE_FILE_UPDATED=true
    fi
else
    log "Creating new service file"
    SERVICE_FILE_UPDATED=true
fi

# Create or update service file if needed
if [ "$SERVICE_FILE_UPDATED" = true ]; then
    log "Writing nginx-proxy-manager.service with current configuration"
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
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    log "Service file created/updated successfully"

    # Reload systemd to apply changes
    log "Reloading systemd daemon"
    systemctl daemon-reload
fi

# Check if service is already enabled
if systemctl is-enabled --quiet nginx-proxy-manager; then
    log "Service is already enabled"
else
    log "Enabling nginx-proxy-manager service"
    systemctl enable nginx-proxy-manager
fi

# Check if service is already running
if systemctl is-active --quiet nginx-proxy-manager; then
    log "Service is already running"

    # If service file was updated, restart the service
    if [ "$SERVICE_FILE_UPDATED" = true ]; then
        log "Service file was updated, restarting service"
        systemctl restart nginx-proxy-manager
    fi
else
    log "Starting nginx-proxy-manager service"
    systemctl start nginx-proxy-manager
fi

# Verify service is running
if systemctl is-active --quiet nginx-proxy-manager; then
    log "Nginx Proxy Manager service is running successfully"
else
    log "ERROR: Failed to start Nginx Proxy Manager service. Check logs with 'journalctl -u nginx-proxy-manager'"
fi

# ===== FINAL SETUP =====
log "Performing final setup tasks"

# Create a script to update the default NPM credentials
cat > /opt/npm/update_credentials.sh << EOF
#!/bin/bash
set -e
trap 'echo "Error occurred at line \$LINENO. Command: \$BASH_COMMAND"' ERR

# Wait for the API to be available
echo "Waiting for Nginx Proxy Manager API to be available..."
MAX_RETRIES=30
RETRY_COUNT=0
API_READY=false

while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
    if curl -s http://localhost:81/api/tokens > /dev/null; then
        API_READY=true
        break
    fi
    RETRY_COUNT=\$((RETRY_COUNT+1))
    echo "Attempt \$RETRY_COUNT/\$MAX_RETRIES - API not ready yet, waiting..."
    sleep 10
done

if [ "\$API_READY" != "true" ]; then
    echo "ERROR: Nginx Proxy Manager API did not become available after \$MAX_RETRIES attempts"
    exit 1
fi

echo "API is available, updating credentials..."

# Update the default credentials
RESPONSE=\$(curl -s -X PUT http://localhost:81/api/users/1 \
  -H "Content-Type: application/json" \
  -d '{
    "email": "${NPM_ADMIN_EMAIL}",
    "name": "Styx Admin",
    "nickname": "admin",
    "password": "${NPM_ADMIN_PASSWORD}",
    "roles": ["admin"]
  }')

# Check if the update was successful
if echo "\$RESPONSE" | grep -q "id"; then
    echo "Credentials updated successfully!"
    exit 0
else
    echo "Failed to update credentials. Response: \$RESPONSE"
    exit 1
fi
EOF

chmod +x /opt/npm/update_credentials.sh

log "Starting credential update script in the background"
nohup /opt/npm/update_credentials.sh > /opt/npm/update_credentials.log 2>&1 &
log "Credential update script started. Check /opt/npm/update_credentials.log for progress"

# Create a status file to indicate successful setup
touch /root/styx_setup_complete

log "Styx setup completed successfully!"
log "Nginx Proxy Manager is available at: http://${DOMAIN_NAME}:81"
log "Please allow a few minutes for all services to start properly."
