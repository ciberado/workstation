#!/bin/bash
# Fix ttyd WebSocket origin checking for HTTPS proxies

set -e

echo "=== Fixing ttyd WebSocket Origin Checking and Font Rendering ==="
echo ""
echo "This adds the -W flag to disable origin checking, which is needed"
echo "when ttyd is behind an HTTPS reverse proxy like Caddy."
echo "Also configures proper font rendering for better readability."
echo ""

# Backup existing service file
if [ -f /etc/systemd/system/ttyd.service ]; then
    cp /etc/systemd/system/ttyd.service /etc/systemd/system/ttyd.service.backup.$(date +%s)
    echo "✅ Backed up existing ttyd.service"
fi

# Create updated service file with -W flag and font configuration
cat << 'EOF' > /etc/systemd/system/ttyd.service
[Unit]
Description=TTYD
After=syslog.target
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd -p 7681 -i 127.0.0.1 -W -t fontSize=16 -t fontFamily="'Courier New', Courier, monospace" login
Type=simple
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

echo "✅ Updated ttyd.service with -W flag and font configuration"
echo ""

# Reload systemd and restart ttyd
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Restarting ttyd service..."
systemctl restart ttyd

echo ""
echo "Waiting 2 seconds for ttyd to start..."
sleep 2

# Check status
echo ""
echo "ttyd status:"
systemctl status ttyd --no-pager | head -15

echo ""
echo "=== Fix Complete ==="
echo ""
echo "ttyd is now configured to:"
echo "  1. Accept WebSocket connections from HTTPS proxies"
echo "  2. Render fonts properly with appropriate spacing"
echo ""
echo "Keypresses should now work in the browser terminal."
echo ""
echo "If you still have issues, try:"
echo "  1. Hard refresh the browser (Ctrl+Shift+R)"
echo "  2. Check ttyd logs: sudo journalctl -u ttyd -f"
