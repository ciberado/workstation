#!/bin/bash

# Termfleet Workstation Registration Service
# This script registers the workstation with the Termfleet management server

set -e

# Configuration (can be overridden by environment variables)
TERMFLEET_ENDPOINT="${TERMFLEET_ENDPOINT:-}"
WORKSTATION_NAME="${WORKSTATION_NAME:-$(hostname)}"
LOG_FILE="/var/log/termfleet-registration.log"
MAX_RETRIES=5
RETRY_DELAY=10

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Get instance IP address
get_ip_address() {
    # Try to get public IP from AWS metadata service
    local ip=$(curl -s --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
    
    if [ -z "$ip" ]; then
        # Fallback to primary network interface IP
        ip=$(hostname -I | awk '{print $1}')
    fi
    
    echo "$ip"
}

# Wait for network connectivity
wait_for_network() {
    log "Waiting for network connectivity..."
    local retries=0
    
    while [ $retries -lt 30 ]; do
        if ping -c 1 8.8.8.8 &> /dev/null; then
            log "Network is available"
            return 0
        fi
        
        log "Network not ready, waiting..."
        sleep 2
        retries=$((retries + 1))
    done
    
    log "ERROR: Network connectivity timeout"
    return 1
}

# Register workstation with Termfleet
register_workstation() {
    local ip="$1"
    local retries=0
    
    log "Attempting to register workstation: $WORKSTATION_NAME with IP: $ip"
    
    while [ $retries -lt $MAX_RETRIES ]; do
        # Make registration request
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
            # Exponential backoff
            RETRY_DELAY=$((RETRY_DELAY * 2))
        fi
    done
    
    log "ERROR: Failed to register after $MAX_RETRIES attempts"
    return 1
}

# Main execution
main() {
    log "=== Termfleet Workstation Registration Started ==="
    
    # Validate configuration
    if [ -z "$TERMFLEET_ENDPOINT" ]; then
        log "ERROR: TERMFLEET_ENDPOINT environment variable is not set"
        log "Usage: TERMFLEET_ENDPOINT=https://termfleet.example.com $0"
        exit 1
    fi
    
    log "Termfleet endpoint: $TERMFLEET_ENDPOINT"
    log "Workstation name: $WORKSTATION_NAME"
    
    # Wait for network
    if ! wait_for_network; then
        exit 1
    fi
    
    # Get IP address
    IP_ADDRESS=$(get_ip_address)
    
    if [ -z "$IP_ADDRESS" ]; then
        log "ERROR: Could not determine IP address"
        exit 1
    fi
    
    log "Detected IP address: $IP_ADDRESS"
    
    # Register workstation
    if register_workstation "$IP_ADDRESS"; then
        log "=== Registration completed successfully ==="
        exit 0
    else
        log "=== Registration failed ==="
        exit 1
    fi
}

# Run main function
main "$@"
