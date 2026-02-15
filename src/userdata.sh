#!/bin/bash

apt update
apt upgrade --assume-yes -y
snap install core; snap refresh core

# =================================================================
# Early DNS Registration (Trigger DNS creation ASAP)
# DNS will propagate in background during all tool installations
# =================================================================

# Configuration
TERMFLEET_ENDPOINT="${TERMFLEET_ENDPOINT:-https://termfleet.example.com}"
FINAL_WORKSTATION_NAME="${WORKSTATION_NAME:-$(hostname)}"
FINAL_BASE_DOMAIN="${BASE_DOMAIN:-}"
LOG_FILE="/var/log/termfleet-registration.log"
DNS_REGISTERED=false

log_message() {
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

register_workstation_early() {
    local ip="$1"
    local max_retries=3
    local retry_delay=5
    local retries=0
    
    log_message "=== Early DNS Registration ==="
    log_message "Registering workstation: $FINAL_WORKSTATION_NAME with IP: $ip"
    
    while [ $retries -lt $max_retries ]; do
        response=$(curl -s -w "\n%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"$FINAL_WORKSTATION_NAME\",\"ip\":\"$ip\"}" \
            "$TERMFLEET_ENDPOINT/api/workstations/register" 2>&1)
        
        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            log_message "DNS registration successful! DNS will propagate during tool installations."
            log_message "Response: $body"
            return 0
        fi
        
        log_message "Registration failed with HTTP $http_code: $body"
        
        retries=$((retries + 1))
        if [ $retries -lt $max_retries ]; then
            log_message "Retrying in $retry_delay seconds... (attempt $retries/$max_retries)"
            sleep $retry_delay
        fi
    done
    
    log_message "ERROR: Failed to register after $max_retries attempts"
    return 1
}

# Trigger DNS registration immediately (if using custom domain)
if [ -n "${FINAL_BASE_DOMAIN}" ] && [ -n "${FINAL_WORKSTATION_NAME}" ]; then
    IP_ADDRESS=$(get_ip_address)
    if [ -n "$IP_ADDRESS" ]; then
        if register_workstation_early "$IP_ADDRESS"; then
            DNS_REGISTERED=true
            DNS_START_TIME=$(date +%s)
            log_message "DNS registration triggered. Installing tools while DNS propagates..."
        else
            log_message "WARNING: Early registration failed, will continue without custom domain"
        fi
    else
        log_message "WARNING: Could not determine IP address for registration"
    fi
else
    log_message "No custom domain configured, will use AWS hostname for Caddy"
fi

# Docker
apt install apt-transport-https ca-certificates curl software-properties-common -y
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable" -y
apt install docker-ce -y
usermod -aG docker ubuntu


# Install and configure tmux

apt install wget tmux -y
wget -O ~/.tmux.conf https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf
wget -O ~/.tmux.conf.local https://raw.githubusercontent.com/gpakosz/.tmux/master/.tmux.conf.local

## tmux on login

cat << EOF >> ~/.bashrc
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

apt install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com jammy main" -y
apt update 
apt install terraform -y

# Install node (with NVM)

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.2/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  
nvm install --lts
n=$(which node);n=${n%/bin/node}; chmod -R 755 $n/bin/*; sudo cp -r $n/{bin,lib,share} /usr/local	

# Install kubectl

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
mv kubectl /usr/local/bin/
chmod +x /usr/local/bin/kubectl

# Install several tools

apt install -y jq

# Set ubuntu user password

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
ExecStart=/usr/local/bin/ttyd -p 7681 -i 127.0.0.1 login
Type=simple
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl start ttyd
sudo systemctl enable ttyd

# =================================================================
# Wait for DNS Propagation (if DNS was registered at script start)
# By now, all tools have been installing while DNS propagates
# =================================================================

wait_for_dns() {
    local domain="$1"
    local max_attempts=30
    local attempt=0
    
    log_message "Checking DNS propagation for: $domain"
    
    while [ $attempt -lt $max_attempts ]; do
        # Try to resolve the domain
        if nslookup "$domain" &>/dev/null; then
            local elapsed=$(($(date +%s) - DNS_START_TIME))
            log_message "DNS resolution successful for $domain (propagated in ${elapsed}s)"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log_message "DNS check $attempt/$max_attempts (waiting 10s)..."
        sleep 10
    done
    
    log_message "WARNING: DNS propagation timeout after $max_attempts attempts"
    log_message "Continuing anyway - Caddy will retry SSL provisioning automatically"
    return 1
}

if [ "$DNS_REGISTERED" = true ]; then
    FULL_DOMAIN="${FINAL_WORKSTATION_NAME}.${FINAL_BASE_DOMAIN}"
    log_message "=== Checking DNS Propagation Before Caddy Setup ==="
    wait_for_dns "$FULL_DOMAIN"
else
    log_message "Skipping DNS propagation check (no custom domain registered)"
fi

# Install and configure Caddy

apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install caddy -y

# Create Caddyfile for reverse proxy to ttyd
# Use custom domain if BASE_DOMAIN is set, otherwise fallback to AWS hostname

if [ -n "${BASE_DOMAIN:-}" ] && [ -n "${WORKSTATION_NAME:-}" ]; then
    # Use custom domain for Termfleet integration
    CADDY_DOMAIN="${WORKSTATION_NAME}.${BASE_DOMAIN}"
    echo "Configuring Caddy with custom domain: ${CADDY_DOMAIN}"
else
    # Fallback to AWS public hostname
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    CADDY_DOMAIN=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)
    echo "Configuring Caddy with AWS hostname: ${CADDY_DOMAIN}"
fi

cat << EOF > /etc/caddy/Caddyfile
${CADDY_DOMAIN} {
	reverse_proxy localhost:7681 {
		header_up Host {host}
		header_up X-Real-IP {remote}
		header_up X-Forwarded-For {remote}
		header_up X-Forwarded-Proto {scheme}
	}
}
EOF

# Enable and start Caddy

sudo systemctl enable caddy
sudo systemctl start caddy

echo "Caddy started with domain: ${CADDY_DOMAIN}"

# =================================================================
# Termfleet Registration Service (for future re-registrations)
# Initial registration completed early in script (right after ttyd setup)
# DNS propagated while tools installed, then Caddy started with valid DNS
# This systemd service is for future IP changes or re-registrations
# =================================================================

echo "Installing Termfleet registration service for future use..."

# Termfleet endpoint configuration
# Set this to your Termfleet server URL (customize before deployment)
TERMFLEET_ENDPOINT="${TERMFLEET_ENDPOINT:-https://termfleet.example.com}"

# Copy registration script from repository or download
# Option 1: If files are in the image/repository
if [ -f /tmp/register-termfleet.sh ]; then
    cp /tmp/register-termfleet.sh /usr/local/bin/
    cp /tmp/termfleet-registration.service /etc/systemd/system/
else
    # Option 2: Download from GitHub or artifact storage
    # wget -O /usr/local/bin/register-termfleet.sh \
    #   https://raw.githubusercontent.com/your-org/workstation/main/src/register-termfleet.sh
    # wget -O /etc/systemd/system/termfleet-registration.service \
    #   https://raw.githubusercontent.com/your-org/workstation/main/src/termfleet-registration.service
    
    # For now, create inline registration script
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
    log "Waiting for network connectivity..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if ping -c 1 8.8.8.8 &> /dev/null; then
            log "Network is available"
            return 0
        fi
        sleep 2
        retries=$((retries + 1))
    done
    log "ERROR: Network connectivity timeout"
    return 1
}

register_workstation() {
    local ip="$1"
    local retries=0
    
    log "Attempting to register workstation: $WORKSTATION_NAME with IP: $ip"
    
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
        log "Response: $body"
        
        retries=$((retries + 1))
        if [ $retries -lt $MAX_RETRIES ]; then
            log "Retrying in $RETRY_DELAY seconds... (attempt $retries/$MAX_RETRIES)"
            sleep $RETRY_DELAY
            RETRY_DELAY=$((RETRY_DELAY * 2))
        fi
    done
    
    log "ERROR: Failed to register after $MAX_RETRIES attempts"
    return 1
}

main() {
    log "=== Termfleet Workstation Registration Started ==="
    
    if [ -z "$TERMFLEET_ENDPOINT" ]; then
        log "ERROR: TERMFLEET_ENDPOINT environment variable is not set"
        exit 1
    fi
    
    log "Termfleet endpoint: $TERMFLEET_ENDPOINT"
    log "Workstation name: $WORKSTATION_NAME"
    
    wait_for_network || exit 1
    
    IP_ADDRESS=$(get_ip_address)
    if [ -z "$IP_ADDRESS" ]; then
        log "ERROR: Could not determine IP address"
        exit 1
    fi
    
    log "Detected IP address: $IP_ADDRESS"
    
    if register_workstation "$IP_ADDRESS"; then
        log "=== Registration completed successfully ==="
        exit 0
    else
        log "=== Registration failed ==="
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
fi

# Make registration script executable
chmod +x /usr/local/bin/register-termfleet.sh

# Create configuration file
# Use WORKSTATION_NAME from environment (set by launch.sh) or fallback to hostname
FINAL_WORKSTATION_NAME="${WORKSTATION_NAME:-$(hostname)}"
FINAL_BASE_DOMAIN="${BASE_DOMAIN:-}"
cat << EOF > /etc/termfleet.conf
# Termfleet Configuration
TERMFLEET_ENDPOINT=${TERMFLEET_ENDPOINT}
WORKSTATION_NAME=${FINAL_WORKSTATION_NAME}
BASE_DOMAIN=${FINAL_BASE_DOMAIN}
EOF

# Enable the service for future use (but don't start now - initial registration already done)
systemctl daemon-reload
systemctl enable termfleet-registration.service

echo "Termfleet registration service installed (enabled for future re-registrations)"
echo "Workstation name: ${FINAL_WORKSTATION_NAME}"
echo "Initial registration completed early in script - DNS propagated during tool installations"
echo "Service will run on future boots or can be triggered manually:"
echo "  systemctl start termfleet-registration.service"
echo "Check status: systemctl status termfleet-registration.service"
echo "View logs: journalctl -u termfleet-registration.service -f"

