# Ops Manager Minimal AWS Bootstrap

This directory contains a minimal bootstrap script for MongoDB Ops Manager on a fresh AWS instance.

The script is intended for evaluation and lab use. It creates a single-node MongoDB Enterprise AppDB, installs Ops Manager, writes the minimal Ops Manager configuration, and starts the services.

## Supported Platforms

- Amazon Linux 2023
- Rocky Linux 8 or 9
- Red Hat Enterprise Linux 8 or 9
- Ubuntu 22.04 or 24.04

Only `x86_64` instances are supported by this script.

## Run From GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/ckh0618/mongoFancyScripts/main/opsman_deploy/install_ops_manager_minimal.sh | bash
```

The script prompts for required usernames, passwords, email addresses, hostnames, and ports. Empty values are rejected until a value is provided.

## Dry Run

Use `DRY_RUN=1` to validate OS detection, prompts, repository configuration, and command flow without changing the system.

```bash
curl -fsSL https://raw.githubusercontent.com/ckh0618/mongoFancyScripts/main/opsman_deploy/install_ops_manager_minimal.sh | DRY_RUN=1 bash
```

For non-interactive dry-run testing, use:

```bash
PROMPT_DEFAULTS=1 DRY_RUN=1 bash opsman_deploy/install_ops_manager_minimal.sh
```

## Validation

After a real EC2 run, verify:

```bash
systemctl status mongod
systemctl status mongodb-mms
curl http://<instance-ip>:8080
```

Open port `8080` in the security group if you need browser access to the Ops Manager UI.
