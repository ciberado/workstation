# Changelog

## 2.2.0 - 2026-02-08

### Added

#### Custom Workstation Names
- Support for specifying workstation name during launch
- Command-line parameter: `./launch.sh <iam_role> [workstation_name]`
- Name validation before launch:
  - 3-63 characters length
  - Alphanumeric and hyphens only
  - Must start and end with alphanumeric character
  - Matches Termfleet DNS requirements
- Instance Name tag set to workstation name (for AWS Console identification)
- Environment variable support: `WORKSTATION_NAME` passed to userdata.sh
- Automatic fallback to AWS hostname if not specified

#### Launch Script Improvements
- Enhanced usage documentation with examples
- Workstation name validation with clear error messages
- Temporary userdata file generation with environment variables
- Automatic cleanup of temporary files

### Changed
- launch.sh now accepts optional second parameter for workstation name
- userdata.sh uses provided WORKSTATION_NAME or falls back to hostname
- Instance tags dynamically updated based on workstation name
- Registration configuration uses custom name instead of AWS hostname

### Technical Details
- Name validation regex: `^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]$`
- Environment variable passed via modified userdata
- Termfleet registration uses custom name for DNS subdomain
- Instance tag: `Name=${WORKSTATION_NAME}` or `Name=workstation`

### Examples
```bash
# Default behavior (use AWS hostname)
./launch.sh LabRole

# Custom workstation names
./launch.sh LabRole desk1
./launch.sh LabRole training-vm-01
./launch.sh LabRole workstation-123

# Via environment variable
export WORKSTATION_NAME=my-desk
./launch.sh LabRole
```

---

## 2.1.0 - 2026-02-08

### Added

#### Termfleet Integration
- Automatic workstation registration with Termfleet management server
- Inline registration script in userdata.sh (self-contained deployment)
- Systemd service for automatic registration on boot
- Configuration file support at /etc/termfleet.conf
- Exponential backoff retry logic (5 attempts, 10s → 160s delays)
- Comprehensive logging to /var/log/termfleet-registration.log
- AWS metadata IP detection with IMDSv2 support
- Fallback to network interface IP if metadata unavailable
- Network connectivity wait with 30-second timeout

#### Registration Features
- POST to Termfleet: `{"name":"hostname","ip":"public_ip"}`
- Automatic DNS subdomain assignment via Spaceship.com
- Health monitoring integration (20-second intervals)
- Real-time status tracking (starting → online → unknown → terminated)
- Dashboard visibility for all workstations
- Idempotent registration (safe to re-run)

#### Documentation
- Complete README.md with:
  - Quick start guide
  - Termfleet integration overview
  - Configuration instructions
  - Troubleshooting section
  - Project structure documentation
  - Security notes and customization guide

### Changed
- userdata.sh now includes Termfleet registration by default
- Registration service starts automatically after network-online.target
- TERMFLEET_ENDPOINT configurable via environment variable
- Workstation name defaults to hostname, customizable via env var

### Technical Details
- Registration script: /usr/local/bin/register-termfleet.sh
- Systemd service: /etc/systemd/system/termfleet-registration.service
- Configuration: /etc/termfleet.conf
- Logs: /var/log/termfleet-registration.log (also in journalctl)
- Retry policy: on-failure with 30s delay, max 5 attempts
- IP detection priority: AWS metadata (IMDSv2) → network interface

### Compatibility
- ✅ Fully compatible with Termfleet 2.1.1
- ✅ Registration API format matches exactly
- ✅ Health check compatible (ttyd serves 200 OK)
- ✅ Name validation passes (alphanumeric + hyphen)
- ✅ IP detection robust (AWS + fallback)
- See: ../termfleet/docs/WORKSTATION_COMPATIBILITY.md

---

## 2.0.1

* Fixed error in ttyd misspelling

# 2.0.0

* New implementation.
