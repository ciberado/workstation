# Workstation

AWS EC2-based web terminal environment with ttyd and automatic Termfleet registration.

## Overview

This project provides automated setup scripts for launching EC2 workstations with web-based terminal access. Each workstation includes:

- **ttyd** - Web-based terminal (runs on localhost:7681)
- **Caddy** - Reverse proxy with automatic HTTPS
- **Termfleet Integration** - Automatic registration with Termfleet management server
- **Development Tools** - Docker, AWS CLI, Terraform, Node.js, kubectl, and more

## Features

- 🚀 **One-command Launch** - Deploy workstation with single script execution
- 🌐 **Web Terminal Access** - Browser-based terminal via ttyd + Caddy
- 🔒 **Automatic HTTPS** - Caddy provides SSL with AWS hostname
- 📡 **Auto-Registration** - Workstations register with Termfleet on boot
- 🛠️ **Pre-installed Tools** - Docker, AWS CLI, Terraform, kubectl, Node.js, tmux
- 🔄 **Health Monitoring** - Termfleet tracks workstation status in real-time
- 📊 **Dashboard Integration** - View all workstations in Termfleet web UI

## Quick Start

### Prerequisites

- AWS account with EC2 permissions
- AWS CLI configured
- IAM role for EC2 instances (e.g., `LabRole`)
- Termfleet server deployed and accessible

### Launch Workstation

```bash
cd src
./launch.sh LabRole
```

This will:
1. Create security group (opens port 443 for HTTPS)
2. Find latest Ubuntu 22.04 AMI
3. Launch t3.medium instance with 8GB storage
4. Execute userdata.sh (installs ttyd, Caddy, tools)
5. Register with Termfleet management server

### Access Workstation

After launch completes:

1. **Find public hostname:**
   ```bash
   # From launch script output
   # Example: ec2-3-14-159-26.compute-1.amazonaws.com
   ```

2. **Access via browser:**
   ```
   https://<public-hostname>
   ```

3. **Login credentials:**
   - Username: `ubuntu`
   - Password: `arch@1234`

4. **Check Termfleet dashboard:**
   - Visit your Termfleet server web UI
   - See workstation status (starting → online)
   - Get assigned domain (e.g., `desk1.ws.aprender.cloud`)

## Termfleet Integration

### What is Termfleet?

Termfleet is a centralized management system for workstations. It provides:
- Automatic DNS subdomain assignment via Spaceship.com
- Real-time health monitoring
- Status dashboard for all workstations
- Lifecycle management (starting → online → unknown → terminated)

### How Integration Works

1. **On Boot:** 
   - `termfleet-registration.service` starts automatically
   - Detects public IP from AWS metadata
   - POSTs registration to Termfleet: `{"name":"hostname","ip":"1.2.3.4"}`

2. **Termfleet Response:**
   - Creates DNS record: `hostname.ws.aprender.cloud → IP`
   - Stores workstation in database with status `starting`
   - Returns domain information

3. **Health Checks:**
   - Termfleet polls workstation every 20 seconds
   - Checks `https://hostname.ws.aprender.cloud/`
   - Successful check transitions status to `online`

4. **Dashboard:**
   - View all workstations in real-time
   - See status, IP, domain, last check time
   - One-click terminal access

### Configuration

Set Termfleet endpoint before launching:

```bash
# Option 1: Environment variable
export TERMFLEET_ENDPOINT=https://your-termfleet-server.com
./launch.sh LabRole

# Option 2: Edit userdata.sh
# Change line: TERMFLEET_ENDPOINT="${TERMFLEET_ENDPOINT:-https://termfleet.example.com}"
```

### Manual Registration

Test registration manually on a running workstation:

```bash
# SSH into workstation
ssh ubuntu@<public-hostname>

# Check registration service status
sudo systemctl status termfleet-registration.service

# View registration logs
sudo journalctl -u termfleet-registration.service -f

# Or view log file
sudo tail -f /var/log/termfleet-registration.log

# Manually trigger registration
sudo TERMFLEET_ENDPOINT=https://your-server.com \
     /usr/local/bin/register-termfleet.sh
```

## Project Structure

```
workstation/
├── src/
│   ├── launch.sh                          # Main launch script
│   ├── userdata.sh                        # EC2 user data (installs everything)
│   ├── register-termfleet.sh              # Termfleet registration script
│   ├── termfleet-registration.service     # Systemd service file
│   └── termfleet.conf.example             # Configuration template
├── docs/
│   └── TERMFLEET_INTEGRATION.md           # Integration documentation
├── README.md                              # This file
└── CHANGELOG.md                           # Version history
```

## Installed Software

### Development Tools

- **Docker** - Container platform
- **AWS CLI v2** - AWS command-line interface
- **Terraform** - Infrastructure as code
- **Node.js** (via nvm) - JavaScript runtime
- **kubectl** - Kubernetes CLI
- **jq** - JSON processor

### Terminal & Environment

- **tmux** - Terminal multiplexer (auto-starts on login)
- **ttyd** - Web-based terminal (localhost:7681)
- **Caddy** - Reverse proxy with automatic HTTPS

### Termfleet Components

- **register-termfleet.sh** - Registration script in `/usr/local/bin/`
- **termfleet-registration.service** - Systemd service
- **termfleet.conf** - Configuration in `/etc/termfleet.conf`

## Customization

### Change Workstation Name

```bash
# In launch.sh, add before launch:
WORKSTATION_NAME="my-desk-01"

# Or in userdata.sh:
WORKSTATION_NAME=my-desk-01
```

### Modify Instance Type

Edit `launch.sh`:

```bash
INSTANCE_TYPE="t3.large"  # Default: t3.medium
VOLUME_SIZE=20            # Default: 8GB
```

### Add Additional Software

Edit `userdata.sh`, add installation commands before the end:

```bash
# Install additional tools
apt install -y vim neovim htop

# Install custom scripts
wget -O /usr/local/bin/my-script.sh https://...
chmod +x /usr/local/bin/my-script.sh
```

## Troubleshooting

### Termfleet Registration Fails

```bash
# Check service status
sudo systemctl status termfleet-registration.service

# View detailed logs
sudo journalctl -xeu termfleet-registration.service

# Check configuration
cat /etc/termfleet.conf

# Test network connectivity to Termfleet
curl -v https://your-termfleet-server.com/health
```

### Workstation Not Appearing in Termfleet

1. **Check registration logs:**
   ```bash
   sudo cat /var/log/termfleet-registration.log
   ```

2. **Verify endpoint is correct:**
   ```bash
   grep TERMFLEET_ENDPOINT /etc/termfleet.conf
   ```

3. **Check IP detection:**
   ```bash
   curl -s http://169.254.169.254/latest/meta-data/public-ipv4
   ```

4. **Manually register:**
   ```bash
   sudo /usr/local/bin/register-termfleet.sh
   ```

### ttyd Not Accessible

```bash
# Check ttyd service
sudo systemctl status ttyd

# Check Caddy service
sudo systemctl status caddy

# View Caddy config
cat /etc/caddy/Caddyfile

# Test local connection
curl http://localhost:7681
```

## Security Notes

- Default password is `arch@1234` - **Change in production!**
- ttyd listens only on localhost (127.0.0.1)
- Caddy provides HTTPS automatically
- Security group opens only port 443 (HTTPS)
- Termfleet registration uses AWS metadata for IP detection

## Documentation

- [Termfleet Integration Guide](docs/TERMFLEET_INTEGRATION.md) - Detailed integration documentation
- [Termfleet Compatibility Analysis](../termfleet/docs/WORKSTATION_COMPATIBILITY.md) - Full compatibility report

## Version History

See [CHANGELOG.md](CHANGELOG.md) for version history and changes.

## License

Internal training environment project.


