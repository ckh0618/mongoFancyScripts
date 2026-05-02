#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/mongodb_os_tuning.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "expected output not to contain: $2"; }

write_os_release() {
  local name="$1" id="$2" version="$3"
  cat > "$TMP_DIR/$name.os-release" <<OS
ID=$id
VERSION_ID="$version"
NAME="$name"
OS
}

write_os_release ubuntu ubuntu 24.04
write_os_release rocky rocky 9.4
write_os_release rhel rhel 9.4
write_os_release amazon amzn 2023
write_os_release unsupported debian 12

bash -n "$SCRIPT"
pass "bash syntax: main script"
bash -n "$0"
pass "bash syntax: test matrix"
[[ -x "$SCRIPT" ]] || fail "main script must be executable"
pass "main script executable"

output="$(OS_RELEASE_FILE="$TMP_DIR/ubuntu.os-release" ARCH_OVERRIDE=x86_64 "$SCRIPT" 2>&1 || true)"
assert_contains "$output" "Mode: report-only"
assert_contains "$output" "Report-only mode: no runtime or persistent changes will be made"
pass "default invocation is report-only/no mutation"

output="$(OS_RELEASE_FILE="$TMP_DIR/ubuntu.os-release" ARCH_OVERRIDE=x86_64 "$SCRIPT" --dry-run 2>&1 || true)"
assert_contains "$output" "THP effective policy: skip"
assert_contains "$output" "MongoDB major version not provided"
pass "missing MongoDB major skips THP with warning when non-interactive"

output="$(OS_RELEASE_FILE="$TMP_DIR/ubuntu.os-release" ARCH_OVERRIDE=x86_64 "$SCRIPT" --dry-run --mongo-major 7 2>&1 || true)"
assert_contains "$output" "THP effective policy: disable"
assert_contains "$output" "net.ipv4.tcp_keepalive_time = 120"
assert_contains "$output" "vm.swappiness = 1"
assert_not_contains "$output" "vm.max_map_count"
assert_not_contains "$output" "net.core.somaxconn"
assert_not_contains "$output" "vm.overcommit_memory"
assert_contains "$output" "mongodb soft nofile 64000"
pass "MongoDB 7 dry-run disables THP, uses exact baseline, and Ubuntu mongodb limits user"

output="$(OS_RELEASE_FILE="$TMP_DIR/ubuntu.os-release" ARCH_OVERRIDE=x86_64 "$SCRIPT" --dry-run --mongo-major 8 2>&1 || true)"
assert_contains "$output" "THP effective policy: enable"
assert_contains "$output" "khugepaged/max_ptes_none"
assert_contains "$output" "/proc/sys/vm/overcommit_memory"
pass "MongoDB 8 x86_64 dry-run enables THP with MongoDB 8 extras"

output="$(OS_RELEASE_FILE="$TMP_DIR/ubuntu.os-release" ARCH_OVERRIDE=aarch64 "$SCRIPT" --dry-run --mongo-major 8 2>&1 || true)"
assert_contains "$output" "THP effective policy: skip"
assert_contains "$output" "scoped to x86_64"
pass "non-x86_64 skips MongoDB 8 THP mutation"

output="$(OS_RELEASE_FILE="$TMP_DIR/rhel.os-release" ARCH_OVERRIDE=x86_64 SYSCTL_SUPPORTED_KEYS=vm.force_cgroup_v2_swappiness "$SCRIPT" --dry-run --mongo-major 7 2>&1 || true)"
assert_contains "$output" "vm.force_cgroup_v2_swappiness = 1"
pass "Red Hat-like supported cgroup swappiness included"

output="$(OS_RELEASE_FILE="$TMP_DIR/rocky.os-release" ARCH_OVERRIDE=x86_64 "$SCRIPT" --dry-run --mongo-major 7 2>&1 || true)"
assert_contains "$output" "Skipping vm.force_cgroup_v2_swappiness"
pass "unsupported cgroup swappiness skipped with report"

for fixture in ubuntu rocky rhel amazon; do
  output="$(OS_RELEASE_FILE="$TMP_DIR/$fixture.os-release" ARCH_OVERRIDE=x86_64 "$SCRIPT" --dry-run --mongo-major 7 2>&1 || true)"
  assert_contains "$output" "Mode: dry-run"
  assert_contains "$output" "THP effective policy: disable"
  if [[ "$fixture" == "ubuntu" ]]; then
    assert_contains "$output" "mongodb soft nofile 64000"
  else
    assert_contains "$output" "mongod soft nofile 64000"
  fi
  pass "supported OS fixture and OS-specific limits user: $fixture"
done

if OS_RELEASE_FILE="$TMP_DIR/unsupported.os-release" ARCH_OVERRIDE=x86_64 "$SCRIPT" --dry-run --mongo-major 7 >/tmp/mongodb_os_tuning_unsupported.out 2>&1; then
  fail "unsupported OS should exit non-zero"
fi
assert_contains "$(cat /tmp/mongodb_os_tuning_unsupported.out)" "Unsupported OS"
pass "unsupported OS exits before mutation"

for required in "/sys/kernel/mm/transparent_hugepage" "/sys/kernel/mm/redhat_transparent_hugepage" "khugepaged/max_ptes_none" "/proc/sys/vm/overcommit_memory" "mongodb-thp-tuning.service" "Before=mongod.service"; do
  grep -q "$required" "$SCRIPT" || fail "script missing required THP/static marker: $required"
done
pass "THP standard/Red Hat paths and standalone unit markers present"

if grep -Eq 'apt(-get)?[[:space:]].*install|dnf[[:space:]].*install|yum[[:space:]].*install|firewall-cmd[[:space:]].*(--add|--remove|--permanent)|ufw[[:space:]].*(allow|deny|enable)|setenforce|semanage|systemctl[[:space:]]+reboot|(^|[;|&])[[:space:]]*reboot([[:space:]]|$)|shutdown[[:space:]]+(-r|--reboot)|mongod\.service\.d|/lib/systemd/system/mongod\.service|/etc/systemd/system/mongod\.service' "$SCRIPT"; then
  fail "prohibited mutation pattern found in script"
fi
pass "prohibited mutation pattern scan"

pass "all OS matrix checks completed"
