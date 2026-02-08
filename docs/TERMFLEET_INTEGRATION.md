# Workstation Integration with Termfleet

This document explains how to integrate the Termfleet registration service with existing workstation instances.

## Overview

The Termfleet registration service automatically registers workstations with the Termfleet management server on boot. It handles:
- Automatic network detection
- IP address resolution
- Retry logic with exponential backoff
- Logging for troubleshooting

## Files

- `register-termfleet.sh` - Main registration script
- `termfleet-registration.service` - Systemd service unit file
- `termfleet.conf.example` - Configuration template

## Installation Steps

### 1. Copy Files to Workstation

Copy the registration files to the appropriate locations:

```bash
# Copy registration script
sudo cp src/register-termfleet.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/register-termfleet.sh

# Copy systemd service file
sudo cp src/termfleet-registration.service /etc/systemd/system/

# Create configuration file
sudo cp src/termfleet.conf.example /etc/termfleet.conf
```

### 2. Configure Termfleet Endpoint

Edit `/etc/termfleet.conf` and set the Termfleet server endpoint:

```bash
sudo nano /etc/termfleet.conf
```

Update:
```
TERMFLEET_ENDPOINT=https://your-termfleet-server.com
```

Optionally set a custom workstation name:
```
WORKSTATION_NAME=desk1
```

### 3. Enable and Start the Service

```bash
# Reload systemd to recognize the new service
sudo systemctl daemon-reload

# Enable service to start on boot
sudo systemctl enable termfleet-registration.service

# Start the service immediately (optional)
sudo systemctl start termfleet-registration.service

# Check service status
sudo systemctl status termfleet-registration.service
```

### 4. View Logs

Check registration logs:

```bash
# View service logs
sudo journalctl -u termfleet-registration.service -f

# View registration log file
sudo tail -f /var/log/termfleet-registration.log
```

## Integration with userdata.sh

To automatically integrate with new workstations, add these lines to `userdata.sh`:

```bash
# Install Termfleet registration service

# Set Termfleet endpoint (customize this)
TERMFLEET_ENDPOINT="https://your-termfleet-server.com"

# Download registration script
wget -O /usr/local/bin/register-termfleet.sh https://raw.githubusercontent.com/your-repo/workstation/main/src/register-termfleet.sh
chmod +x /usr/local/bin/register-termfleet.sh

# Download systemd service file
wget -O /etc/systemd/system/termfleet-registration.service https://raw.githubusercontent.com/your-repo/workstation/main/src/termfleet-registration.service

# Create configuration file
cat << EOF > /etc/termfleet.conf
TERMFLEET_ENDPOINT=${TERMFLEET_ENDPOINT}
WORKSTATION_NAME=$(hostname)
EOF

# Enable and start service
systemctl daemon-reload
systemctl enable termfleet-registration.service
systemctl start termfleet-registration.service

echo "Termfleet registration service installed and started"
```

### Integration Point in existing userdata.sh

Add the Termfleet registration after Caddy installation but before the end of the script:

```bash
# ... existing userdata.sh content ...

apt install caddy -y

# ADD TERMFLEET REGISTRATION HERE
# (insert the code from above)

# Rest of the script continues...
```

## Troubleshooting

### Service not starting

```bash
# Check service status
sudo systemctl status termfleet-registration.service

# View detailed logs
sudo journalctl -xeu termfleet-registration.service
```

### Registration failing

1. Check network connectivity:
   ```bash
   ping -c 3 your-termfleet-server.com
   ```

2. Test registration manually:
   ```bash
   TERMFLEET_ENDPOINT=https://your-termfleet-server.com \
   /usr/local/bin/register-termfleet.sh
   ```

3. Check registration logs:
   ```bash
   less /var/log/termfleet-registration.log
   ```

### Common Issues

**Issue**: "TERMFLEET_ENDPOINT environment variable is not set"
- **Solution**: Ensure `/etc/termfleet.conf` exists and contains the endpoint

**Issue**: "Network connectivity timeout"
- **Solution**: Check internet connection and DNS resolution

**Issue**: "Failed to register after N attempts"
- **Solution**: Check Termfleet server is running and accessible

## Manual Testing

Test the registration manually:

```bash
# Set environment variables
export TERMFLEET_ENDPOINT=https://your-termfleet-server.com
export WORKSTATION_NAME=test-workstation

# Run registration script
/usr/local/bin/register-termfleet.sh
```

## Uninstallation

To remove the Termfleet registration service:

```bash
# Stop and disable service
sudo systemctl stop termfleet-registration.service
sudo systemctl disable termfleet-registration.service

# Remove files
sudo rm /usr/local/bin/register-termfleet.sh
sudo rm /etc/systemd/system/termfleet-registration.service
sudo rm /etc/termfleet.conf
sudo rm /var/log/termfleet-registration.log

# Reload systemd
sudo systemctl daemon-reload
```

## Security Considerations

- The registration endpoint is public (no authentication required by design)
- Workstation names should be unique
- IP addresses are automatically detected
- Logs may contain sensitive information (IP addresses, domain names)

## Next Steps

Once registered, workstations will:
1. Appear in the Termfleet dashboard with "starting" status
2. Transition to "online" once health checks succeed
3. Automatically recover if connectivity is temporarily lost
4. Be marked "terminated" if offline for too long
