# MongoDB Production Note: OS Tuning

Offline-friendly MongoDB production OS tuning helpers for:

- Ubuntu
- Rocky Linux
- Red Hat Enterprise Linux
- Amazon Linux 2023

The directory name is shell-friendly (`production_note`) and corresponds to the requested “production Note”.

## Safety model

Default execution is **report-only** and does not change the host. Use `--dry-run` to inspect planned writes and commands. Use `--apply` only after reviewing the report.

This script does **not**:

- install MongoDB or configure MongoDB package repositories
- install operating-system packages
- change firewall rules
- change SELinux mode or policy
- reboot the host
- edit `mongod.service` or create `mongod` systemd drop-ins
- change IP, hostname, mounts, filesystems, partitions, or disk layout

## Online usage from GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/ckh0618/mongoFancyScripts/main/production_note/mongodb_os_tuning.sh | bash
```

Dry-run before applying:

```bash
curl -fsSL https://raw.githubusercontent.com/ckh0618/mongoFancyScripts/main/production_note/mongodb_os_tuning.sh | bash -s -- --dry-run --mongo-major 7
curl -fsSL https://raw.githubusercontent.com/ckh0618/mongoFancyScripts/main/production_note/mongodb_os_tuning.sh | sudo bash -s -- --apply --mongo-major 7
```

For MongoDB 8 on supported `x86_64` hosts:

```bash
curl -fsSL https://raw.githubusercontent.com/ckh0618/mongoFancyScripts/main/production_note/mongodb_os_tuning.sh | bash -s -- --dry-run --mongo-major 8
curl -fsSL https://raw.githubusercontent.com/ckh0618/mongoFancyScripts/main/production_note/mongodb_os_tuning.sh | sudo bash -s -- --apply --mongo-major 8
```

## Offline usage

Copy the script to the target host, then run:

```bash
chmod +x mongodb_os_tuning.sh
./mongodb_os_tuning.sh
./mongodb_os_tuning.sh --dry-run --mongo-major 7
sudo ./mongodb_os_tuning.sh --apply --mongo-major 7
```

No internet access is required for normal report, dry-run, or apply behavior. The script never uses the network at runtime; `curl` is only one way to retrieve the file.

## What it tunes or checks

- Transparent Huge Pages (THP):
  - MongoDB 7 or earlier: plans/applies THP disablement.
  - MongoDB 8 on `x86_64`: plans/applies THP enablement by default, including `enabled=always`, `defrag=defer+madvise`, `khugepaged/max_ptes_none=0`, and `vm.overcommit_memory=1`, reflecting current MongoDB guidance for updated TCMalloc.
  - If MongoDB major is not provided during interactive `--dry-run` or `--apply`, the script asks whether the host is for MongoDB 8.0 or newer and sets THP from that answer. In non-interactive execution without `--mongo-major`, THP mutation is skipped with a warning.
- `sysctl` baseline:
  - `net.ipv4.tcp_keepalive_time = 120`
  - `vm.swappiness = 1`
  - `vm.force_cgroup_v2_swappiness = 1` only on compatible Red-Hat-family kernels where the key exists
- `limits.d` baseline for the MongoDB OS user: Ubuntu defaults to `mongodb`; Rocky, RHEL, and Amazon Linux 2023 default to `mongod`. `nofile` and `nproc` are set to `64000`.
- NUMA: advisory report only. Missing commands or NUMA metadata produce warnings but do not fail the script.
- Time sync: advisory report only. Missing `timedatectl`/`systemctl` support produces warnings but does not fail the script.

## Options

```text
--report-only          inspect without changing the host (default)
--dry-run              print planned writes/commands
--apply                apply runtime values and write persistent configuration; requires root
--mongo-major 7|8      choose MongoDB major version for THP policy
--thp-policy auto|disable|enable|skip
--mongod-user USER     OS user for limits entries; default Ubuntu=mongodb, others=mongod
```

## Validation

From the repository root:

```bash
bash -n production_note/mongodb_os_tuning.sh
bash -n production_note/test_os_matrix.sh
production_note/test_os_matrix.sh
```

## References

- MongoDB Production Notes: https://www.mongodb.com/docs/manual/administration/production-notes/
- MongoDB THP guidance: https://www.mongodb.com/docs/manual/tutorial/disable-transparent-huge-pages/
- MongoDB UNIX ulimit guidance: https://www.mongodb.com/docs/manual/reference/ulimit/index.html
