#!/bin/bash
# Fix Caddy configuration to enable HTTPS

set -e

echo "=== Fixing Caddy HTTPS Configuration ==="
echo ""

# Get instance metadata
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_HOSTNAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

echo "Instance public hostname: ${PUBLIC_HOSTNAME}"
echo "Instance public IP: ${PUBLIC_IP}"
echo ""

# Check if there's a domain from Termfleet registration
ASSIGNED_DOMAIN=""
if [ -f /tmp/termfleet_domain ]; then
    ASSIGNED_DOMAIN=$(cat /tmp/termfleet_domain)
    echo "Found Termfleet domain from registration: ${ASSIGNED_DOMAIN}"
fi

# Also try to extract from logs as fallback
TERMFLEET_LOG="/var/log/userdata.log"
if [ -z "$ASSIGNED_DOMAIN" ] && [ -f "${TERMFLEET_LOG}" ]; then
    # Try to extract the assigned domain from the registration response
    ASSIGNED_DOMAIN=$(grep -oP '"domain_name":\s*"\K[^"]+' "${TERMFLEET_LOG}" 2>/dev/null | head -1 || echo "")
    if [ -n "$ASSIGNED_DOMAIN" ]; then
        echo "Extracted domain from logs: ${ASSIGNED_DOMAIN}"
        # Save it for future use
        echo "$ASSIGNED_DOMAIN" > /tmp/termfleet_domain
    fi
fi

# Determine which domain to use
if [ -n "$ASSIGNED_DOMAIN" ]; then
    CADDY_DOMAIN="$ASSIGNED_DOMAIN"
    echo "Using Termfleet-assigned domain: ${CADDY_DOMAIN}"
    
    # Verify DNS resolution
    RESOLVED_IP=$(dig +short "$CADDY_DOMAIN" | head -1)
    echo "DNS check: ${CADDY_DOMAIN} resolves to ${RESOLVED_IP}"
    
    if [ "$RESOLVED_IP" != "$PUBLIC_IP" ]; then
        echo "⚠️  WARNING: DNS doesn't match instance IP yet"
        echo "   Expected: ${PUBLIC_IP}"
        echo "   Got: ${RESOLVED_IP}"
        echo "   Waiting 30 seconds for DNS propagation..."
        sleep 30
    fi
else
    CADDY_DOMAIN="$PUBLIC_HOSTNAME"
    echo "Using AWS public hostname: ${CADDY_DOMAIN}"
fi

echo ""
echo "Creating new Caddyfile with domain: ${CADDY_DOMAIN}"

# Backup existing Caddyfile
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup.$(date +%s)

# Create new Caddyfile with proper domain - MUST include https:// prefix
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

echo "New Caddyfile content:"
cat /etc/caddy/Caddyfile
echo ""

# Reload Caddy
echo "Reloading Caddy..."
systemctl reload caddy

echo ""
echo "Waiting 5 seconds for Caddy to reload..."
sleep 5

# Check status
echo ""
echo "Caddy status:"
systemctl status caddy --no-pager | head -20

echo ""
echo "Ports now listening:"
ss -tlnp | grep caddy || echo "No Caddy ports found"

echo ""
echo "=== Fix Complete ==="
echo ""
echo "If DNS is properly configured, Caddy will:"
echo "1. Automatically obtain a Let's Encrypt certificate"
echo "2. Listen on both port 80 (HTTP) and port 443 (HTTPS)"
echo "3. Redirect HTTP to HTTPS automatically"
echo ""
echo "Access your terminal at: https://${CADDY_DOMAIN}"
echo ""
echo "Check Caddy logs if issues persist:"
echo "  sudo journalctl -u caddy -f"
