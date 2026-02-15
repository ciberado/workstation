#!/bin/bash
apt update
apt upgrade --assume-yes -y
snap install core; snap refresh core

# Early DNS Registration - triggers DNS propagation during tool installation
TERMFLEET_ENDPOINT="${TERMFLEET_ENDPOINT:-https://termfleet.aprender.cloud}"
FINAL_WORKSTATION_NAME="${WORKSTATION_NAME:-}"
LOG_FILE="/var/log/termfleet-registration.log"
DNS_REGISTERED=false
ASSIGNED_DOMAIN=""

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
    log_message "Registering: $FINAL_WORKSTATION_NAME IP: $ip"
    
    while [ $retries -lt $max_retries ]; do
        response=$(curl -s -w "\n%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"$FINAL_WORKSTATION_NAME\",\"ip\":\"$ip\"}" \
            "$TERMFLEET_ENDPOINT/api/workstations/register" 2>&1)
        
        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
        
        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
            log_message "DNS registration successful!"
            log_message "Response: $body"
            
            # Extract domain from response
            local extracted_domain=$(echo "$body" | grep -o '"domain_name":"[^"]*"' | cut -d'"' -f4)
            if [ -n "$extracted_domain" ]; then
                log_message "Assigned domain: $extracted_domain"
                echo "$extracted_domain" > /tmp/termfleet_domain
            else
                log_message "WARNING: Could not extract domain"
            fi
            
            return 0
        fi
        
        log_message "Registration failed with HTTP $http_code: $body"
        
        retries=$((retries + 1))
        if [ $retries -lt $max_retries ]; then
            log_message "Retrying in ${retry_delay}s (attempt $retries/$max_retries)"
            sleep $retry_delay
        fi
    done
    
    log_message "ERROR: Failed to register after $max_retries attempts"
    return 1
}

# Trigger DNS registration if workstation name provided
if [ -n "${FINAL_WORKSTATION_NAME}" ]; then
    IP_ADDRESS=$(get_ip_address)
    if [ -n "$IP_ADDRESS" ]; then
        if register_workstation_early "$IP_ADDRESS"; then
            DNS_REGISTERED=true
            DNS_START_TIME=$(date +%s)
            log_message "DNS registration triggered, installing tools..."
        else
            log_message "WARNING: Early registration failed"
        fi
    else
        log_message "WARNING: Could not determine IP"
    fi
else
    log_message "No name provided, using AWS hostname"
fi

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

# Install node with NVM
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.2/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  
nvm install --lts
n=$(which node);n=${n%/bin/node}; chmod -R 755 $n/bin/*; sudo cp -r $n/{bin,lib,share} /usr/local	

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

# Wait for DNS propagation if DNS was registered
wait_for_dns() {
    local domain="$1"
    local max_attempts=30
    local attempt=0
    
    log_message "Checking DNS for: $domain"
    
    while [ $attempt -lt $max_attempts ]; do
        if nslookup "$domain" &>/dev/null; then
            local elapsed=$(($(date +%s) - DNS_START_TIME))
            log_message "DNS resolved in ${elapsed}s"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log_message "DNS check $attempt/$max_attempts"
        sleep 10
    done
    
    log_message "WARNING: DNS timeout, Caddy will retry"
    return 1
}

if [ "$DNS_REGISTERED" = true ] && [ -n "$ASSIGNED_DOMAIN" ]; then
    log_message "Checking DNS before Caddy setup"
    wait_for_dns "$ASSIGNED_DOMAIN"
else
    log_message "Skipping DNS check"
fi

# Install Caddy
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install caddy -y

# Configure Caddy with Termfleet domain or AWS hostname
if [ -f /tmp/termfleet_domain ]; then
    CADDY_DOMAIN=$(cat /tmp/termfleet_domain)
else
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    CADDY_DOMAIN=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)
fi

log_message "Configuring Caddy for: ${CADDY_DOMAIN}"

cat << EOF > /etc/caddy/Caddyfile
https://${CADDY_DOMAIN} {
	reverse_proxy localhost:7681 {
		header_up Host {host}
		header_up X-Real-IP {remote}
		header_up X-Forwarded-For {remote}
		header_up X-Forwarded-Proto {scheme}
	}
}
EOF

log_message "Caddy configured for: ${CADDY_DOMAIN}"

# Start Caddy
sudo systemctl enable caddy
sudo systemctl start caddy
log_message "Caddy started"

# Install Termfleet registration service for future use
if [ -f /tmp/register-termfleet.sh ]; then
    cp /tmp/register-termfleet.sh /usr/local/bin/
    cp /tmp/termfleet-registration.service /etc/systemd/system/
else
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

