# Repository Guidelines

## Project Structure & Module Organization

This repository provisions an AWS EC2 workstation with a browser terminal and
Termfleet registration. Operational scripts live in `src/`:

- `src/launch.sh` creates or starts the EC2 workstation, networking resources,
  and passes cloud-init data.
- `src/destroy.sh` removes the Termfleet registration, Elastic IP, and EC2
  instance.
- `src/userdata.sh` is the Ubuntu cloud-init payload; it installs and configures
  Docker, ttyd, Caddy, tmux, and registration services.
- `docs/TERMFLEET_INTEGRATION.md` documents the Termfleet protocol. Keep
  user-facing setup and behavior changes reflected in `README.md` and
  `CHANGELOG.md`.

## Build, Test, and Development Commands

There is no compiled build or automated test suite. Validate shell changes
before review:

```bash
bash -n src/launch.sh src/destroy.sh src/userdata.sh  # syntax check
shellcheck src/*.sh                                   # lint, if installed
```

Run infrastructure actions only against an intended AWS account and region:

```bash
cd src
./launch.sh desk1       # provision or start a named workstation
./destroy.sh desk1      # interactive, irreversible teardown
```

Use `./destroy.sh -y desk1` only in deliberate non-interactive automation.

## Coding Style & Naming Conventions

Write Bash compatible with the existing scripts. Use four-space indentation,
`UPPER_SNAKE_CASE` for configuration and environment variables, and descriptive
lowercase names for local variables and functions (for example, `log_message`).
Quote variable expansions unless word splitting is explicitly needed. Preserve
`set -e`, existing logging, and explicit AWS `--region` options. ShellCheck
findings should be resolved or briefly justified in the PR.

## Testing Guidelines

After static checks, manually exercise changed argument validation or dry
read-only AWS queries where practical. For `userdata.sh` changes, verify the
generated service configuration and cloud-init logs on a disposable instance;
check `systemctl status ttyd` and `/var/log/workstation-setup.log`.

## Commit & Pull Request Guidelines

History favors concise imperative subjects, such as `Fix ttyd rendering issue:`
or `Add destroy.sh script`. Keep commits focused and describe affected scripts.
PRs should explain operational impact, configuration changes, validation run,
and any AWS resources or security exposure affected. Include relevant terminal
output or screenshots for user-visible terminal/Caddy changes, and link the
tracking issue when one exists.

## Security & Configuration

Never commit credentials, private key files, account identifiers, or production
endpoints. Treat changes to security-group rules, IAM roles, public ports, and
the default Termfleet endpoint as security-sensitive; document their effect and
test them in a non-production account first.

Keep configuration consistent across scripts and documentation. For CLI
changes, update environment precedence, validation, help, examples, and
dependent provisioning or teardown behavior.
