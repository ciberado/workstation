#!/bin/bash
set -e

apt update
apt upgrade --assume-yes -y
snap install core; snap refresh core

LOG_FILE="/var/log/workstation-setup.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_message "Starting workstation setup..."

# Docker
apt install apt-transport-https ca-certificates curl software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install docker-ce docker-ce-cli containerd.io -y
usermod -aG docker ubuntu

# Install tmux
apt install wget tmux -y
wget -O /home/ubuntu/.tmux.conf https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf
wget -O /home/ubuntu/.tmux.conf.local https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf.local
chown ubuntu:ubuntu /home/ubuntu/.tmux.conf /home/ubuntu/.tmux.conf.local

# tmux on login
cat << EOF >> /home/ubuntu/.bashrc
if [[ -z \$TMUX ]]; then
  tmux attach -t default || tmux new -s default
fi
EOF

# Install AWS CLI v2
apt install unzip -y
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws

# Install Terraform
apt install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
apt update 
apt install terraform -y

# Install node with NVM (install as ubuntu user, then copy to system)
# First install NVM for ubuntu user
su - ubuntu -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.2/install.sh | bash'
# Install LTS node as ubuntu user and copy to system path
su - ubuntu -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm install --lts'
# Copy node to system path for all users
NODE_PATH=$(su - ubuntu -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && which node')
NODE_DIR=$(dirname $(dirname $NODE_PATH))
cp -r $NODE_DIR/bin/* /usr/local/bin/ 2>/dev/null || true
cp -r $NODE_DIR/lib/* /usr/local/lib/ 2>/dev/null || true
cp -r $NODE_DIR/share/* /usr/local/share/ 2>/dev/null || true
chmod -R 755 /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx 2>/dev/null || true

# Install kubectl and tools
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
mv kubectl /usr/local/bin/
chmod +x /usr/local/bin/kubectl
apt install -y jq

# Configure ubuntu password
echo "ubuntu:arch@1234" | chpasswd

# Configure ttyd
wget -O /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64
chmod +x /usr/local/bin/ttyd

cat << EOF > /etc/systemd/system/ttyd.service
[Unit]
Description=TTYD
After=syslog.target
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd -p 7681 -i 127.0.0.1 -W -t fontSize=16 -t fontFamily="'Courier New', Courier, monospace" su - ubuntu
Type=simple
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl start ttyd
sudo systemctl enable ttyd

# Install Caddy (configuration will happen after EIP association)
log_message "Installing Caddy..."
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install caddy -y

# Give Caddy permission to bind to privileged ports (443, 80)
setcap 'cap_net_bind_service=+ep' /usr/bin/caddy
log_message "Caddy installed with network capabilities"

# Create script that waits for stable IP, registers DNS, and configures Caddy
cat << 'EOFSCRIPT' > /usr/local/bin/setup-caddy-dns.sh
#!/bin/bash

# Source config file if available (for systemd service calls)
[ -f /etc/termfleet.conf ] && source /etc/termfleet.conf

# Fallback defaults
TERMFLEET_ENDPOINT="${TERMFLEET_ENDPOINT:-https://termfleet.aprender.cloud}"
WORKSTATION_NAME="${WORKSTATION_NAME:-}"
LOG="/var/log/workstation-setup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [setup-caddy-dns] $1" | tee -a "$LOG"; }

log "Starting Caddy DNS setup..."
log "WORKSTATION_NAME: ${WORKSTATION_NAME:-<not set>}"
log "TERMFLEET_ENDPOINT: ${TERMFLEET_ENDPOINT}"

get_public_ip() {
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4
}

# Wait for IP to stabilize (detects EIP association)
log "Waiting for IP to stabilize..."
PREV_IP=""
STABLE_COUNT=0
while [ $STABLE_COUNT -lt 6 ]; do
    CURRENT_IP=$(get_public_ip)
    if [ "$CURRENT_IP" = "$PREV_IP" ] && [ -n "$CURRENT_IP" ]; then
        STABLE_COUNT=$((STABLE_COUNT + 1))
    else
        STABLE_COUNT=0
        PREV_IP="$CURRENT_IP"
    fi
    sleep 5
done

log "IP stable: $CURRENT_IP"

# Register with Termfleet if workstation name provided
if [ -n "$WORKSTATION_NAME" ]; then
    log "Registering with Termfleet..."
    RESP=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$WORKSTATION_NAME\",\"ip\":\"$CURRENT_IP\"}" \
        "$TERMFLEET_ENDPOINT/api/workstations/register" 2>&1)
    
    CODE=$(echo "$RESP" | tail -n1)
    BODY=$(echo "$RESP" | sed '$d')
    
    if [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; then
        log "DNS registered successfully"
        DOMAIN=$(echo "$BODY" | grep -o '"domain_name":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$DOMAIN" ]; then
            log "Assigned domain: $DOMAIN"
        else
            DOMAIN="${WORKSTATION_NAME}.ws.aprender.cloud"
        fi
        
        # Disable this service - EIP is stable, no need to re-register on reboot
        log "Disabling setup-caddy-dns.service (EIP is stable, registration complete)"
        systemctl disable setup-caddy-dns.service 2>/dev/null || true
    else
        log "Registration failed (HTTP $CODE), using fallback"
        DOMAIN="${WORKSTATION_NAME}.ws.aprender.cloud"
        # Keep service enabled to retry on next boot
        log "Service will retry on next boot"
    fi
else
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    DOMAIN=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)
fi

log "Configuring Caddy for: $DOMAIN"

# Wait for DNS to resolve (if using custom domain)
if [ -n "$WORKSTATION_NAME" ]; then
    log "Waiting for DNS resolution..."
    DNS_RETRIES=0
    while [ $DNS_RETRIES -lt 30 ]; do
        if nslookup "$DOMAIN" > /dev/null 2>&1; then
            log "DNS resolved successfully for $DOMAIN"
            break
        fi
        DNS_RETRIES=$((DNS_RETRIES + 1))
        sleep 2
    done
    
    if [ $DNS_RETRIES -ge 30 ]; then
        log "WARNING: DNS not resolving yet, but continuing with configuration"
    fi
fi

# Configure Caddyfile - Caddy 2 will automatically handle HTTPS
cat > /etc/caddy/Caddyfile << EOF
{
	# Disable admin API for security
	admin off
}

# Main domain configuration with automatic HTTPS
$DOMAIN {
	reverse_proxy localhost:7681 {
		header_up Host {host}
		header_up X-Real-IP {remote}
		header_up X-Forwarded-For {remote}
		header_up X-Forwarded-Proto {scheme}
	}
}

# Fallback for direct IP access
http://:80 {
	redir https://$DOMAIN{uri} permanent
}
EOF

systemctl enable caddy
systemctl restart caddy
log "Caddy configured and started"
EOFSCRIPT

chmod +x /usr/local/bin/setup-caddy-dns.sh

# Create systemd service
cat > /etc/systemd/system/setup-caddy-dns.service << 'EOFSERVICE'
[Unit]
Description=Setup Caddy after EIP association
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/termfleet.conf
ExecStart=/usr/local/bin/setup-caddy-dns.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOFSERVICE

systemctl daemon-reload
systemctl enable setup-caddy-dns.service
log_message "Caddy DNS service created and enabled"

# Install Termfleet registration service
cat << 'REGSCRIPT' > /usr/local/bin/register-termfleet.sh
#!/bin/bash
set -e

# Configuration
TERMFLEET_ENDPOINT="${TERMFLEET_ENDPOINT:-}"
WORKSTATION_NAME="${WORKSTATION_NAME:-$(hostname)}"
LOG_FILE="/var/log/termfleet-registration.log"
MAX_RETRIES=5
RETRY_DELAY=10

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

get_ip_address() {
    # Try AWS metadata with IMDSv2
    local token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")
    if [ -n "$token" ]; then
        local ip=$(curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    fi
    
    # Fallback to primary network interface IP
    hostname -I | awk '{print $1}'
}

wait_for_network() {
    log "Waiting for network..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if ping -c 1 8.8.8.8 &> /dev/null; then
            log "Network available"
            return 0
        fi
        sleep 2
        retries=$((retries + 1))
    done
    log "ERROR: Network timeout"
    return 1
}

register_workstation() {
    local ip="$1"
    local retries=0
    
    log "Registering: $WORKSTATION_NAME IP: $ip"
    
    while [ $retries -lt $MAX_RETRIES ]; do
        response=$(curl -s -w "\n%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"$WORKSTATION_NAME\",\"ip\":\"$ip\"}" \
            "$TERMFLEET_ENDPOINT/api/workstations/register" 2>&1)
        
        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            log "Registration successful!"
            log "Response: $body"
            return 0
        fi
        
        log "Registration failed with HTTP $http_code"
        
        retries=$((retries + 1))
        if [ $retries -lt $MAX_RETRIES ]; then
            log "Retry in ${RETRY_DELAY}s (attempt $retries/$MAX_RETRIES)"
            sleep $RETRY_DELAY
            RETRY_DELAY=$((RETRY_DELAY * 2))
        fi
    done
    
    log "ERROR: Failed to register after $MAX_RETRIES attempts"
    return 1
}

main() {
    log "=== Termfleet Registration ==="
    
    if [ -z "$TERMFLEET_ENDPOINT" ]; then
        log "ERROR: TERMFLEET_ENDPOINT not set"
        exit 1
    fi
    
    log "Endpoint: $TERMFLEET_ENDPOINT"
    log "Name: $WORKSTATION_NAME"
    
    wait_for_network || exit 1
    
    IP_ADDRESS=$(get_ip_address)
    if [ -z "$IP_ADDRESS" ]; then
        log "ERROR: No IP found"
        exit 1
    fi
    
    log "IP: $IP_ADDRESS"
    
    if register_workstation "$IP_ADDRESS"; then
        log "=== Registration complete ==="
        # Disable this service - EIP is stable, no need to re-register on reboot
        log "Disabling termfleet-registration.service (EIP is stable)"
        systemctl disable termfleet-registration.service 2>/dev/null || true
        exit 0
    else
        log "=== Registration failed ==="
        log "Service will retry on next boot"
        exit 1
    fi
}

main "$@"
REGSCRIPT

    # Create systemd service
    cat << 'SERVFILE' > /etc/systemd/system/termfleet-registration.service
[Unit]
Description=Termfleet Workstation Registration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/termfleet.conf
ExecStart=/usr/local/bin/register-termfleet.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

# Retry on failure
Restart=on-failure
RestartSec=30s
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
SERVFILE

# Make registration script executable
chmod +x /usr/local/bin/register-termfleet.sh

# Create configuration file for future registrations
# Use WORKSTATION_NAME from environment (set by launch.sh) - may be empty for AWS hostname mode
# For the systemd service, we need a name, so use hostname as fallback for service config only
SERVICE_WORKSTATION_NAME="${WORKSTATION_NAME:-$(hostname)}"
cat << EOF > /etc/termfleet.conf
# Termfleet Configuration
TERMFLEET_ENDPOINT=${TERMFLEET_ENDPOINT}
WORKSTATION_NAME=${SERVICE_WORKSTATION_NAME}
EOF

# Only enable the service if we're using Termfleet (workstation name was provided)
systemctl daemon-reload
if [ -n "${WORKSTATION_NAME}" ]; then
    systemctl enable termfleet-registration.service
    echo "Termfleet registration service installed and enabled"
    echo "Workstation name: ${WORKSTATION_NAME}"
    echo "Service will run on future boots or can be triggered manually:"
    echo "  systemctl start termfleet-registration.service"
else
    echo "Termfleet registration service installed but NOT enabled (AWS hostname mode)"
    echo "To enable later: systemctl enable termfleet-registration.service"
fi
echo "Check status: systemctl status termfleet-registration.service"
echo "View logs: journalctl -u termfleet-registration.service -f"

# Now run the Caddy DNS setup (config file is now available)
log_message "Running Caddy DNS setup..."
/usr/local/bin/setup-caddy-dns.sh || log_message "WARNING: Caddy DNS setup failed, will retry on reboot"

log_message "======================================"
log_message "Workstation setup complete!"
log_message "======================================"

