#!/bin/bash

apt update
apt upgrade --assume-yes -y
snap install core; snap refresh core

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

# Install and configure Caddy

apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install caddy -y

# Create Caddyfile for reverse proxy to ttyd
# Get public hostname from EC2 metadata (using IMDSv2)

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_HOSTNAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)

cat << EOF > /etc/caddy/Caddyfile
${PUBLIC_HOSTNAME} {
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

# =================================================================
# Termfleet Registration Service
# Automatically registers this workstation with Termfleet management
# =================================================================

echo "Installing Termfleet registration service..."

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
cat << EOF > /etc/termfleet.conf
# Termfleet Configuration
TERMFLEET_ENDPOINT=${TERMFLEET_ENDPOINT}
WORKSTATION_NAME=$(hostname)
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable termfleet-registration.service
systemctl start termfleet-registration.service

echo "Termfleet registration service installed and started"
echo "Check status: systemctl status termfleet-registration.service"
echo "View logs: journalctl -u termfleet-registration.service -f"

