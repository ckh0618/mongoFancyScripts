#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

MODE="report-only"
MONGO_MAJOR="${MONGO_MAJOR:-}"
THP_POLICY="${THP_POLICY:-auto}"
MONGOD_USER="${MONGOD_USER:-}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
ARCH_VALUE="${ARCH_OVERRIDE:-${UNAME_M_OVERRIDE:-}}"
SYSCTL_SUPPORTED_KEYS="${SYSCTL_SUPPORTED_KEYS:-}"
DRY_RUN="${DRY_RUN:-0}"

OS_ID=""
OS_VERSION_ID=""
OS_FAMILY=""
ARCH=""
THP_EFFECTIVE_POLICY="skip"
THP_SKIP_REASON=""
SYSCTL_FILE="/etc/sysctl.d/99-mongodb-production.conf"
LIMITS_FILE="/etc/security/limits.d/99-mongodb-production.conf"
THP_UNIT_FILE="/etc/systemd/system/mongodb-thp-tuning.service"

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [--report-only|--dry-run|--apply] [--mongo-major 7|8] [--thp-policy auto|disable|enable|skip] [--mongod-user USER]

MongoDB production OS tuning helper for Ubuntu, Rocky, RHEL, and Amazon Linux 2023.
Default mode is report-only and does not mutate the host.

Options:
  --report-only          Inspect and print a report without changing files or runtime values (default)
  --dry-run              Print planned writes/commands without changing the host
  --apply                Apply runtime values and write persistent configuration (requires root)
  --mongo-major 7|8      Select MongoDB major version for THP policy decisions
                         If omitted in an interactive apply/dry-run, the script asks whether MongoDB is 8.0 or newer.
  --thp-policy POLICY    Override THP policy: auto, disable, enable, or skip
  --mongod-user USER     OS user for limits.d entries (default: Ubuntu=mongodb, others=mongod)
  --help                 Show this help

Test hooks:
  OS_RELEASE_FILE        Read OS metadata from a fixture instead of /etc/os-release
  ARCH_OVERRIDE          Override uname -m for tests
  SYSCTL_SUPPORTED_KEYS  Comma-separated sysctl keys considered available for tests
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --report-only) MODE="report-only" ;;
      --dry-run) MODE="dry-run"; DRY_RUN=1 ;;
      --apply) MODE="apply" ;;
      --mongo-major)
        [[ $# -ge 2 ]] || die "--mongo-major requires a value"
        MONGO_MAJOR="$2"; shift ;;
      --mongo-major=*) MONGO_MAJOR="${1#*=}" ;;
      --thp-policy)
        [[ $# -ge 2 ]] || die "--thp-policy requires a value"
        THP_POLICY="$2"; shift ;;
      --thp-policy=*) THP_POLICY="${1#*=}" ;;
      --mongod-user)
        [[ $# -ge 2 ]] || die "--mongod-user requires a value"
        MONGOD_USER="$2"; shift ;;
      --mongod-user=*) MONGOD_USER="${1#*=}" ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done

  case "$MODE" in report-only|dry-run|apply) ;; *) die "Invalid mode: $MODE" ;; esac
  case "$THP_POLICY" in auto|disable|enable|skip) ;; *) die "Invalid --thp-policy: $THP_POLICY" ;; esac
  if [[ -n "$MONGO_MAJOR" && ! "$MONGO_MAJOR" =~ ^[0-9]+$ ]]; then
    die "--mongo-major must be numeric"
  fi
  if [[ -n "$MONGOD_USER" && ! "$MONGOD_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "--mongod-user must contain only letters, numbers, dot, underscore, or hyphen"
  fi
}

load_os_release() {
  [[ -r "$OS_RELEASE_FILE" ]] || die "Cannot read OS release file: $OS_RELEASE_FILE"
  # shellcheck disable=SC1090
  . "$OS_RELEASE_FILE"
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  case "$OS_ID" in
    ubuntu) OS_FAMILY="debian" ;;
    rocky|rhel) OS_FAMILY="redhat" ;;
    amzn)
      if [[ "$OS_VERSION_ID" == "2023" || "$OS_VERSION_ID" == 2023.* ]]; then
        OS_FAMILY="amazon2023"
      else
        die "Unsupported Amazon Linux version: ${OS_VERSION_ID:-unknown}"
      fi
      ;;
    *) die "Unsupported OS: ${OS_ID:-unknown}" ;;
  esac
}

load_arch() {
  if [[ -n "$ARCH_VALUE" ]]; then
    ARCH="$ARCH_VALUE"
  else
    ARCH="$(uname -m)"
  fi
}

set_default_mongod_user() {
  if [[ -n "$MONGOD_USER" ]]; then
    return 0
  fi

  case "$OS_ID" in
    ubuntu) MONGOD_USER="mongodb" ;;
    rocky|rhel|amzn) MONGOD_USER="mongod" ;;
    *) MONGOD_USER="mongod" ;;
  esac
}

prompt_mongo_major_if_needed() {
  if [[ "$THP_POLICY" != "auto" || -n "$MONGO_MAJOR" || "$MODE" == "report-only" ]]; then
    return 0
  fi

  local answer=""
  local prompt="Is this host for MongoDB 8.0 or newer? [y/N]: "

  if [[ -t 0 ]]; then
    read -r -p "$prompt" answer || answer=""
  elif [[ -t 1 ]] && { printf '%s' "$prompt" > /dev/tty && IFS= read -r answer < /dev/tty; } 2>/dev/null; then
    :
  else
    warn "MongoDB major version was not provided and no interactive terminal is available; THP mutation will be skipped."
    return 0
  fi

  case "$answer" in
    y|Y|yes|YES|Yes) MONGO_MAJOR="8" ;;
    *) MONGO_MAJOR="7" ;;
  esac
  log "Using MongoDB major ${MONGO_MAJOR} based on interactive answer."
}

require_root_for_apply() {
  if [[ "$MODE" == "apply" && "$(id -u)" != "0" ]]; then
    die "--apply requires root privileges. Run report-only/dry-run first, then use sudo for apply."
  fi
}

run_cmd() {
  if [[ "$MODE" == "dry-run" || "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
  elif [[ "$MODE" == "apply" ]]; then
    "$@"
  else
    printf '[REPORT-ONLY] would run:'
    printf ' %q' "$@"
    printf '\n'
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  if [[ "$MODE" == "dry-run" || "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN] write %s:\n%s\n' "$path" "$content"
  elif [[ "$MODE" == "apply" ]]; then
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "$content" > "$tmp"
    install -m 0644 "$tmp" "$path"
    rm -f "$tmp"
    log "Wrote $path"
  else
    printf '[REPORT-ONLY] would write %s:\n%s\n' "$path" "$content"
  fi
}

sysctl_key_supported() {
  local key="$1"
  local proc_path="/proc/sys/${key//./\/}"
  if [[ -n "$SYSCTL_SUPPORTED_KEYS" ]]; then
    case ",$SYSCTL_SUPPORTED_KEYS," in
      *",$key,"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  [[ -e "$proc_path" ]]
}

is_redhat_like_for_cgroup_swappiness() {
  case "$OS_ID" in
    rhel|rocky|amzn) return 0 ;;
    *) return 1 ;;
  esac
}

sysctl_content() {
  cat <<SYSCTL
# MongoDB production OS tuning baseline managed by $SCRIPT_NAME
# See MongoDB production notes: TCP keepalive 120s and low swappiness.
net.ipv4.tcp_keepalive_time = 120
vm.swappiness = 1
SYSCTL
  if is_redhat_like_for_cgroup_swappiness && sysctl_key_supported "vm.force_cgroup_v2_swappiness"; then
    printf 'vm.force_cgroup_v2_swappiness = 1\n'
  fi
}

apply_sysctl_runtime() {
  run_cmd sysctl -w net.ipv4.tcp_keepalive_time=120
  run_cmd sysctl -w vm.swappiness=1
  if is_redhat_like_for_cgroup_swappiness && sysctl_key_supported "vm.force_cgroup_v2_swappiness"; then
    run_cmd sysctl -w vm.force_cgroup_v2_swappiness=1
  else
    log "Skipping vm.force_cgroup_v2_swappiness; key is not supported or OS is not Red Hat-like."
  fi
}

limits_content() {
  cat <<LIMITS
# MongoDB production limits managed by $SCRIPT_NAME
$MONGOD_USER soft nofile 64000
$MONGOD_USER hard nofile 64000
$MONGOD_USER soft nproc 64000
$MONGOD_USER hard nproc 64000
LIMITS
}

resolve_thp_policy() {
  THP_EFFECTIVE_POLICY="skip"
  THP_SKIP_REASON=""
  if [[ "$THP_POLICY" == "skip" ]]; then
    THP_SKIP_REASON="--thp-policy skip requested"
    return
  fi
  if [[ "$THP_POLICY" == "disable" || "$THP_POLICY" == "enable" ]]; then
    THP_EFFECTIVE_POLICY="$THP_POLICY"
  else
    if [[ -z "$MONGO_MAJOR" ]]; then
      THP_SKIP_REASON="MongoDB major version not provided; pass --mongo-major 7 (disable THP) or 8 (enable THP), or override with --thp-policy."
      return
    elif (( MONGO_MAJOR >= 8 )); then
      THP_EFFECTIVE_POLICY="enable"
    else
      THP_EFFECTIVE_POLICY="disable"
    fi
  fi

  if [[ "$THP_EFFECTIVE_POLICY" == "enable" && "$ARCH" != "x86_64" ]]; then
    THP_SKIP_REASON="MongoDB 8 THP enablement is scoped to x86_64 in this first pass; detected arch: $ARCH."
    THP_EFFECTIVE_POLICY="skip"
  fi
}

thp_sysfs_dirs() {
  printf '%s\n' \
    /sys/kernel/mm/transparent_hugepage \
    /sys/kernel/mm/redhat_transparent_hugepage
}

thp_value_for_file() {
  local file_name="$1"
  case "$THP_EFFECTIVE_POLICY:$file_name" in
    disable:enabled) printf 'never' ;;
    disable:defrag) printf 'never' ;;
    enable:enabled) printf 'always' ;;
    enable:defrag) printf 'defer+madvise' ;;
    *) printf '' ;;
  esac
}

apply_proc_value() {
  local path="$1"
  local value="$2"

  if [[ "$MODE" == "apply" ]]; then
    if [[ -w "$path" ]]; then
      printf '%s\n' "$value" > "$path" || warn "Could not write $value to $path"
    else
      warn "Cannot write $path; skipping value $value"
    fi
  else
    printf '[%s] would write %s to %s\n' "${MODE^^}" "$value" "$path"
  fi
}

apply_thp_runtime() {
  if [[ "$THP_EFFECTIVE_POLICY" == "skip" ]]; then
    warn "Skipping THP mutation: $THP_SKIP_REASON"
    return 0
  fi

  local found=0 dir file_name value file_path max_ptes_path
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    found=1
    for file_name in enabled defrag; do
      file_path="$dir/$file_name"
      [[ -w "$file_path" || "$MODE" != "apply" ]] || continue
      [[ -e "$file_path" || "$MODE" != "apply" ]] || continue
      value="$(thp_value_for_file "$file_name")"
      [[ -n "$value" ]] || continue
      apply_proc_value "$file_path" "$value"
    done

    if [[ "$THP_EFFECTIVE_POLICY" == "enable" ]]; then
      max_ptes_path="$dir/khugepaged/max_ptes_none"
      if [[ -e "$max_ptes_path" || "$MODE" != "apply" ]]; then
        apply_proc_value "$max_ptes_path" "0"
      fi
    fi
  done < <(thp_sysfs_dirs)

  if [[ "$THP_EFFECTIVE_POLICY" == "enable" ]]; then
    apply_proc_value "/proc/sys/vm/overcommit_memory" "1"
  fi

  if [[ "$found" == "0" ]]; then
    warn "No known THP sysfs directory found; checked standard and Red Hat derivative paths."
  fi
}
thp_unit_content() {
  local script_body value_enabled value_defrag
  value_enabled="$(thp_value_for_file enabled)"
  value_defrag="$(thp_value_for_file defrag)"
  if [[ "$THP_EFFECTIVE_POLICY" == "enable" ]]; then
    script_body="for d in /sys/kernel/mm/transparent_hugepage /sys/kernel/mm/redhat_transparent_hugepage; do [ -d \"\$d\" ] || continue; [ -w \"\$d/enabled\" ] && echo $value_enabled > \"\$d/enabled\" || true; [ -w \"\$d/defrag\" ] && echo $value_defrag > \"\$d/defrag\" || true; [ -w \"\$d/khugepaged/max_ptes_none\" ] && echo 0 > \"\$d/khugepaged/max_ptes_none\" || true; done; [ -w /proc/sys/vm/overcommit_memory ] && echo 1 > /proc/sys/vm/overcommit_memory || true"
  else
    script_body="for d in /sys/kernel/mm/transparent_hugepage /sys/kernel/mm/redhat_transparent_hugepage; do [ -d \"\$d\" ] || continue; [ -w \"\$d/enabled\" ] && echo $value_enabled > \"\$d/enabled\" || true; [ -w \"\$d/defrag\" ] && echo $value_defrag > \"\$d/defrag\" || true; done"
  fi
  cat <<UNIT
[Unit]
Description=MongoDB THP policy tuning
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service mongodb-mms-automation-agent.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '$script_body'

[Install]
WantedBy=multi-user.target
UNIT
}
persist_thp_policy() {
  if [[ "$THP_EFFECTIVE_POLICY" == "skip" ]]; then
    log "No persistent THP unit planned because THP policy is skip."
    return 0
  fi
  write_file "$THP_UNIT_FILE" "$(thp_unit_content)"
  if [[ "$MODE" == "apply" || "$MODE" == "dry-run" || "$DRY_RUN" == "1" ]]; then
    run_cmd systemctl daemon-reload
    run_cmd systemctl enable mongodb-thp-tuning.service
  else
    printf '[REPORT-ONLY] would enable standalone THP unit: %s\n' "$THP_UNIT_FILE"
  fi
}

report_numa() {
  local node_count=0
  if [[ -d /sys/devices/system/node ]]; then
    node_count="$(find /sys/devices/system/node -maxdepth 1 -type d -name 'node[0-9]*' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ "${node_count:-0}" -gt 1 ]]; then
    warn "NUMA appears enabled with $node_count nodes. Review MongoDB NUMA guidance manually; this script does not modify services."
  else
    log "NUMA check: ${node_count:-0} NUMA node(s) detected or NUMA info unavailable."
  fi
}

report_time_sync() {
  if command -v timedatectl >/dev/null 2>&1; then
    log "Time sync status from timedatectl:"
    timedatectl 2>/dev/null | sed 's/^/  /' || warn "timedatectl failed"
  else
    warn "timedatectl not found; verify NTP/chrony/systemd-timesyncd manually."
  fi

  if command -v systemctl >/dev/null 2>&1; then
    for svc in chronyd systemd-timesyncd; do
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        log "Time sync service active: $svc"
      fi
    done
  fi
}

print_report() {
  cat <<REPORT

==== MongoDB Production OS Tuning Report ====
Mode: $MODE
OS: $OS_ID ${OS_VERSION_ID:-} (family: $OS_FAMILY)
Architecture: $ARCH
MongoDB major: ${MONGO_MAJOR:-not provided}
THP requested policy: $THP_POLICY
THP effective policy: $THP_EFFECTIVE_POLICY${THP_SKIP_REASON:+ ($THP_SKIP_REASON)}
Sysctl file: $SYSCTL_FILE
Limits file: $LIMITS_FILE
THP unit file: $THP_UNIT_FILE
Mongod OS user for limits: $MONGOD_USER

Non-goal boundaries honored:
- No MongoDB package/repository installation
- No package installation
- No firewall mutation
- No SELinux mutation
- No automatic reboot
- No mongod systemd unit/drop-in modification
- No destructive network/disk mutation

Manual follow-up:
- Existing sessions/services may need restart or re-login to pick up limits.d changes.
- Review NUMA and time synchronization warnings above.
- Run --dry-run before --apply on production hosts.
============================================
REPORT
}

main() {
  parse_args "$@"
  load_os_release
  load_arch
  set_default_mongod_user
  prompt_mongo_major_if_needed
  require_root_for_apply
  resolve_thp_policy

  log "Mode: $MODE"
  log "Detected OS: $OS_ID ${OS_VERSION_ID:-} ($OS_FAMILY), arch: $ARCH"

  if [[ "$ARCH" != "x86_64" ]]; then
    warn "First pass is scoped to x86_64. Non-THP report checks continue, but THP mutation is skipped when applicable."
  fi

  if [[ "$MODE" == "apply" || "$MODE" == "dry-run" || "$DRY_RUN" == "1" ]]; then
    apply_thp_runtime
    persist_thp_policy
    write_file "$SYSCTL_FILE" "$(sysctl_content)"
    apply_sysctl_runtime
    write_file "$LIMITS_FILE" "$(limits_content)"
  else
    log "Report-only mode: no runtime or persistent changes will be made."
    apply_thp_runtime
    persist_thp_policy
    write_file "$SYSCTL_FILE" "$(sysctl_content)"
    write_file "$LIMITS_FILE" "$(limits_content)"
  fi

  report_numa
  report_time_sync
  print_report
}

main "$@"
