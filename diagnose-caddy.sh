#!/bin/bash
# Diagnostic script to check Caddy configuration

echo "=== Caddy Configuration Diagnosis ==="
echo ""

echo "1. Current Caddyfile content:"
echo "----------------------------"
cat /etc/caddy/Caddyfile
echo ""
echo ""

echo "2. Expected domain (from metadata):"
echo "----------------------------"
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_HOSTNAME=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Public hostname: ${PUBLIC_HOSTNAME}"
echo "Public IP: ${PUBLIC_IP}"

# Check if Termfleet assigned a domain
if [ -f /tmp/termfleet_domain ]; then
    TERMFLEET_DOMAIN=$(cat /tmp/termfleet_domain)
    echo "Termfleet domain (from /tmp/termfleet_domain): ${TERMFLEET_DOMAIN}"
else
    echo "No Termfleet domain file found (/tmp/termfleet_domain missing)"
fi
echo ""

echo "3. DNS resolution check:"
echo "----------------------------"
# Extract domain from Caddyfile
DOMAIN=$(grep -E '^[a-zA-Z0-9]' /etc/caddy/Caddyfile | grep -v '{' | head -1 | tr -d ' ')
echo "Domain in Caddyfile: ${DOMAIN}"
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != ":80" ] && [ "$DOMAIN" != ":443" ]; then
    RESOLVED_IP=$(dig +short "$DOMAIN" | head -1)
    echo "Resolves to: ${RESOLVED_IP}"
    if [ "$RESOLVED_IP" = "$PUBLIC_IP" ]; then
        echo "✅ DNS correctly points to this instance"
    else
        echo "❌ DNS mismatch! DNS: ${RESOLVED_IP}, Instance: ${PUBLIC_IP}"
    fi
else
    echo "⚠️  No domain found or using port-only config"
fi
echo ""

echo "4. Ports listening:"
echo "----------------------------"
ss -tlnp | grep caddy
echo ""

echo "5. Caddy service status:"
echo "----------------------------"
systemctl status caddy --no-pager -l | tail -20
