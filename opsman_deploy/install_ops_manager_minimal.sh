#!/usr/bin/env bash
set -Eeuo pipefail

# Minimal MongoDB Ops Manager bootstrap for fresh AWS instances.
# This script is intended for evaluation environments, not production.

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly DEFAULT_DATA_DIR="appdb"
readonly DEFAULT_MONGO_PORT="27017"
readonly DEFAULT_OPSMAN_PORT="8080"
readonly DEFAULT_ADMIN_EMAIL="admin@example.com"

DRY_RUN="${DRY_RUN:-0}"
PROMPT_DEFAULTS="${PROMPT_DEFAULTS:-0}"

OS_ID=""
OS_VERSION_ID=""
OS_VERSION_MAJOR=""
OS_CODENAME=""
OS_FAMILY=""
ARCH=""
SUDO=""
PACKAGE_MANAGER=""
MONGODB_OS_USER=""

OPSMAN_MAJOR=""
OPSMAN_VERSION=""
OPSMAN_DEB_URL=""
OPSMAN_RPM_URL=""
MONGODB_MAJOR=""

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_shell() {
  local command="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN] %s\n' "$command"
    return 0
  fi
  bash -c "$command"
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

show_service_logs() {
  local service_name="$1"

  [[ "$DRY_RUN" == "1" ]] && return 0
  command -v journalctl >/dev/null 2>&1 || return 0

  printf '\n[%s] Last logs for %s:\n' "$SCRIPT_NAME" "$service_name" >&2
  $SUDO journalctl -u "$service_name" -n 80 --no-pager >&2 || true
}

url_encode() {
  local input="$1"
  local output=""
  local i char

  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        output+="$char"
        ;;
      *)
        printf -v output '%s%%%02X' "$output" "'$char"
        ;;
    esac
  done

  printf '%s' "$output"
}

validate_identifier() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 ))
}

validate_host() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._:-]+$ ]]
}

validate_email() {
  local value="$1"
  [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local secret="${4:-0}"
  local validator="${5:-}"
  local value=""

  if [[ "$PROMPT_DEFAULTS" == "1" && -n "$default_value" ]]; then
    if [[ -n "$validator" ]] && ! "$validator" "$default_value"; then
      die "Default value for ${var_name} failed validation."
    fi
    printf -v "$var_name" '%s' "$default_value"
    log "Using default value for ${var_name} because PROMPT_DEFAULTS=1."
    return 0
  fi

  while true; do
    if [[ "$secret" == "1" ]]; then
      read -r -s -p "${prompt_text}: " value
      printf '\n'
    else
      if [[ -n "$default_value" ]]; then
        read -r -p "${prompt_text} [${default_value}]: " value
        value="${value:-$default_value}"
      else
        read -r -p "${prompt_text}: " value
      fi
    fi

    if [[ -n "$value" ]]; then
      if [[ -n "$validator" ]] && ! "$validator" "$value"; then
        log "Invalid value. Please try again."
        continue
      fi
      printf -v "$var_name" '%s' "$value"
      return 0
    fi

    log "This value is required. Please enter a non-empty value."
  done
}

select_from_menu() {
  local var_name="$1"
  local prompt_text="$2"
  shift 2
  local options=("$@")
  local choice=""

  while true; do
    log "$prompt_text"
    local index=1
    local option
    for option in "${options[@]}"; do
      printf '  %d) %s\n' "$index" "$option"
      index=$((index + 1))
    done

    if [[ "$PROMPT_DEFAULTS" == "1" ]]; then
      choice="1"
      log "Using menu option 1 because PROMPT_DEFAULTS=1."
    else
      read -r -p "Select an option: " choice
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      printf -v "$var_name" '%s' "${options[$((choice - 1))]}"
      return 0
    fi

    log "Invalid selection. Please choose one of the listed numbers."
  done
}

detect_platform() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is not readable."
  # shellcheck disable=SC1091
  source /etc/os-release

  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_VERSION_MAJOR="${OS_VERSION_ID%%.*}"
  ARCH="$(uname -m)"

  [[ "$ARCH" == "x86_64" ]] || die "Only x86_64 is supported by this bootstrap script. Detected: $ARCH"

  case "$OS_ID" in
    ubuntu)
      OS_FAMILY="ubuntu"
      PACKAGE_MANAGER="apt"
      MONGODB_OS_USER="mongodb"
      [[ "$OS_VERSION_ID" == "22.04" || "$OS_VERSION_ID" == "24.04" ]] || die "Supported Ubuntu versions are 22.04 and 24.04. Detected: $OS_VERSION_ID"
      [[ -n "$OS_CODENAME" ]] || die "Ubuntu codename could not be detected."
      ;;
    amzn)
      OS_FAMILY="amazon"
      MONGODB_OS_USER="mongod"
      if [[ "$OS_VERSION_ID" == "2023" ]]; then
        PACKAGE_MANAGER="dnf"
      else
        die "Supported Amazon Linux version is 2023. Detected: $OS_VERSION_ID"
      fi
      ;;
    rhel | rocky)
      OS_FAMILY="rhel"
      PACKAGE_MANAGER="dnf"
      MONGODB_OS_USER="mongod"
      [[ "$OS_VERSION_MAJOR" == "8" || "$OS_VERSION_MAJOR" == "9" ]] || die "Supported RHEL/Rocky major versions are 8 and 9. Detected: $OS_VERSION_ID"
      ;;
    *)
      die "Unsupported OS: ${OS_ID:-unknown}"
      ;;
  esac

  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
  else
    need_command sudo
    SUDO="sudo"
  fi

  log "Detected platform: ${OS_ID} ${OS_VERSION_ID} (${ARCH})"
  log "Using MongoDB OS account: ${MONGODB_OS_USER}"
}

configure_versions() {
  select_from_menu OPSMAN_MAJOR "Select Ops Manager release family." "8.0"

  case "$OPSMAN_MAJOR" in
    8.0)
      OPSMAN_VERSION="8.0.22"
      OPSMAN_DEB_URL="https://downloads.mongodb.com/on-prem-mms/deb/mongodb-mms-8.0.22.500.20260407T1112Z.amd64.deb"
      OPSMAN_RPM_URL="https://downloads.mongodb.com/on-prem-mms/rpm/mongodb-mms-8.0.22.500.20260407T1111Z.x86_64.rpm"
      OPSMAN_DEB_URL="${OPSMAN_DEB_URL_OVERRIDE:-$OPSMAN_DEB_URL}"
      OPSMAN_RPM_URL="${OPSMAN_RPM_URL_OVERRIDE:-$OPSMAN_RPM_URL}"
      select_from_menu MONGODB_MAJOR "Select compatible MongoDB AppDB release family." "8.0"
      ;;
    *)
      die "Unsupported Ops Manager release family: $OPSMAN_MAJOR"
      ;;
  esac

  log "Selected Ops Manager ${OPSMAN_VERSION} and MongoDB AppDB ${MONGODB_MAJOR}."
}

install_prerequisites() {
  log "Installing prerequisite packages."
  case "$OS_FAMILY" in
    ubuntu)
      run $SUDO apt-get update
      run $SUDO apt-get install -y ca-certificates curl gnupg openssl wget
      ;;
    amazon)
      run $SUDO "$PACKAGE_MANAGER" install -y ca-certificates openssl wget
      if ! command -v curl >/dev/null 2>&1; then
        run $SUDO "$PACKAGE_MANAGER" install -y curl-minimal
      fi
      ;;
    rhel)
      run $SUDO "$PACKAGE_MANAGER" install -y ca-certificates curl openssl wget
      ;;
  esac
}

configure_mongodb_repo() {
  log "Configuring MongoDB Enterprise ${MONGODB_MAJOR} repository."

  case "$OS_FAMILY" in
    ubuntu)
      run_shell "curl -fsSL https://pgp.mongodb.com/server-${MONGODB_MAJOR}.asc | ${SUDO:+$SUDO }gpg -o /usr/share/keyrings/mongodb-server-${MONGODB_MAJOR}.gpg --dearmor"
      run_shell "echo 'deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${MONGODB_MAJOR}.gpg ] https://repo.mongodb.com/apt/ubuntu ${OS_CODENAME}/mongodb-enterprise/${MONGODB_MAJOR} multiverse' | ${SUDO:+$SUDO }tee /etc/apt/sources.list.d/mongodb-enterprise-${MONGODB_MAJOR}.list >/dev/null"
      run $SUDO apt-get update
      ;;
    amazon)
      run_shell "${SUDO:+$SUDO }tee /etc/yum.repos.d/mongodb-enterprise-${MONGODB_MAJOR}.repo >/dev/null <<EOF
[mongodb-enterprise-${MONGODB_MAJOR}]
name=MongoDB Enterprise Repository
baseurl=https://repo.mongodb.com/yum/amazon/2023/mongodb-enterprise/${MONGODB_MAJOR}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-${MONGODB_MAJOR}.asc
EOF"
      ;;
    rhel)
      run_shell "${SUDO:+$SUDO }tee /etc/yum.repos.d/mongodb-enterprise-${MONGODB_MAJOR}.repo >/dev/null <<EOF
[mongodb-enterprise-${MONGODB_MAJOR}]
name=MongoDB Enterprise Repository
baseurl=https://repo.mongodb.com/yum/redhat/\$releasever/mongodb-enterprise/${MONGODB_MAJOR}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-${MONGODB_MAJOR}.asc
EOF"
      ;;
  esac
}

install_mongodb() {
  log "Installing MongoDB Enterprise."
  case "$OS_FAMILY" in
    ubuntu)
      run $SUDO apt-get install -y mongodb-enterprise
      ;;
    amazon | rhel)
      run $SUDO "$PACKAGE_MANAGER" install -y mongodb-enterprise
      ;;
  esac
}

write_mongod_config() {
  local datadir="$1"
  local port="$2"
  local db_path="/data/${datadir}1"

  log "Preparing MongoDB AppDB data path and configuration."
  run $SUDO mkdir -p "$db_path"
  run $SUDO chown -R "${MONGODB_OS_USER}:${MONGODB_OS_USER}" "$db_path"
  run_shell "openssl rand -base64 756 | ${SUDO:+$SUDO }tee /etc/mongodb.key >/dev/null"
  run $SUDO chmod 400 /etc/mongodb.key
  run $SUDO chown "${MONGODB_OS_USER}:${MONGODB_OS_USER}" /etc/mongodb.key

  run_shell "${SUDO:+$SUDO }tee /etc/mongod.conf >/dev/null <<EOF
systemLog:
  destination: file
  logAppend: true
  path: ${db_path}/mongod.log

storage:
  dbPath: ${db_path}
  wiredTiger:
    engineConfig:
      cacheSizeGB: 2

processManagement:
  fork: false
  pidFilePath: /var/run/mongodb/mongod.pid
  timeZoneInfo: /usr/share/zoneinfo

net:
  port: ${port}
  bindIpAll: true

security:
  authorization: enabled
  keyFile: /etc/mongodb.key
EOF"
}

start_mongodb() {
  log "Starting MongoDB AppDB."
  run $SUDO systemctl enable mongod
  run $SUDO systemctl restart mongod

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  for _ in {1..30}; do
    if mongosh --quiet --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  show_service_logs mongod
  die "mongod did not become ready in time."
}

create_appdb_user() {
  local mongo_user="$1"
  local mongo_password="$2"
  local port="$3"

  log "Creating MongoDB AppDB root user."
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN] MONGO_APPDB_USER=<provided> MONGO_APPDB_PASSWORD=<provided> mongosh --port %q --quiet --eval %q\n' \
      "$port" \
      "db.getSiblingDB('admin').createUser({user: process.env.MONGO_APPDB_USER, pwd: process.env.MONGO_APPDB_PASSWORD, roles: [{db: 'admin', role: 'root'}]})"
    return 0
  fi

  MONGO_APPDB_USER="$mongo_user" MONGO_APPDB_PASSWORD="$mongo_password" \
    mongosh --port "$port" --quiet --eval "db.getSiblingDB('admin').createUser({user: process.env.MONGO_APPDB_USER, pwd: process.env.MONGO_APPDB_PASSWORD, roles: [{db: 'admin', role: 'root'}]})"
}

install_ops_manager() {
  local package_file="/tmp/mongodb-mms-package"

  log "Installing MongoDB Ops Manager ${OPSMAN_VERSION}."
  case "$OS_FAMILY" in
    ubuntu)
      run curl -fsSL "$OPSMAN_DEB_URL" -o "${package_file}.deb"
      run $SUDO apt-get install -y "${package_file}.deb"
      ;;
    amazon | rhel)
      run curl -fsSL "$OPSMAN_RPM_URL" -o "${package_file}.rpm"
      run $SUDO "$PACKAGE_MANAGER" install -y "${package_file}.rpm"
      ;;
  esac
}

write_ops_manager_config() {
  local mongo_user="$1"
  local mongo_password="$2"
  local mongo_host="$3"
  local mongo_port="$4"
  local opsman_host="$5"
  local opsman_port="$6"
  local admin_email="$7"
  local from_email="$8"
  local reply_to_email="$9"
  local encoded_user=""
  local encoded_password=""
  local mongo_uri=""

  encoded_user="$(url_encode "$mongo_user")"
  encoded_password="$(url_encode "$mongo_password")"
  mongo_uri="mongodb://${encoded_user}:${encoded_password}@${mongo_host}:${mongo_port}/admin"

  log "Writing Ops Manager minimal configuration."
  if [[ "$DRY_RUN" == "1" ]]; then
    cat <<EOF
[DRY-RUN] tee /opt/mongodb/mms/conf/conf-mms.properties >/dev/null <<EOF_CONFIG
mongo.mongoUri=mongodb://<encoded-user>:<encoded-password>@${mongo_host}:${mongo_port}/admin
mongo.encryptedCredentials=false
mms.ignoreInitialUiSetup=true
mms.centralUrl=http://${opsman_host}:${opsman_port}
mms.https.ClientCertificateMode=none
mms.adminEmailAddr=${admin_email}
mms.fromEmailAddr=${from_email}
mms.replyToEmailAddr=${reply_to_email}
mms.mail.hostname=localhost
mms.mail.port=25
mms.mail.ssl=false
mms.mail.transport=smtp
mongo.ssl=false
automation.versions.source=hybrid
EOF_CONFIG
EOF
    return 0
  fi

  run_shell "${SUDO:+$SUDO }tee /opt/mongodb/mms/conf/conf-mms.properties >/dev/null <<EOF
mongo.mongoUri=${mongo_uri}
mongo.encryptedCredentials=false
mms.ignoreInitialUiSetup=true
mms.centralUrl=http://${opsman_host}:${opsman_port}
mms.https.ClientCertificateMode=none
mms.adminEmailAddr=${admin_email}
mms.fromEmailAddr=${from_email}
mms.replyToEmailAddr=${reply_to_email}
mms.mail.hostname=localhost
mms.mail.port=25
mms.mail.ssl=false
mms.mail.transport=smtp
mongo.ssl=false
automation.versions.source=hybrid
EOF"
  run $SUDO chown mongodb-mms:mongodb-mms /opt/mongodb/mms/conf/conf-mms.properties
  run $SUDO chmod 600 /opt/mongodb/mms/conf/conf-mms.properties
}

start_ops_manager() {
  log "Starting MongoDB Ops Manager."
  run $SUDO systemctl enable mongodb-mms
  run $SUDO systemctl restart mongodb-mms

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  sleep 5
  if ! $SUDO systemctl is-active --quiet mongodb-mms; then
    show_service_logs mongodb-mms
    die "mongodb-mms did not start successfully."
  fi
}

detect_default_host() {
  local detected=""
  detected="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "$detected" ]]; then
    detected="$(hostname --ip-address 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "$detected"
}

main() {
  local mongo_user=""
  local mongo_password=""
  local datadir=""
  local mongo_port=""
  local opsman_port=""
  local default_host=""
  local central_host=""
  local appdb_host=""
  local admin_email=""
  local from_email=""
  local reply_to_email=""
  local default_mongo_password=""

  detect_platform
  configure_versions

  default_host="$(detect_default_host)"
  [[ -n "$default_host" ]] || default_host="127.0.0.1"

  prompt_required mongo_user "MongoDB AppDB admin username" "admin" "0" validate_identifier
  if [[ "$PROMPT_DEFAULTS" == "1" ]]; then
    default_mongo_password="${TEST_DEFAULT_MONGO_PASSWORD:-dry-run-password}"
  fi
  prompt_required mongo_password "MongoDB AppDB admin password" "$default_mongo_password" "1"
  prompt_required datadir "MongoDB AppDB data directory name" "$DEFAULT_DATA_DIR" "0" validate_identifier
  prompt_required mongo_port "MongoDB AppDB port" "$DEFAULT_MONGO_PORT" "0" validate_port
  prompt_required appdb_host "MongoDB AppDB host for Ops Manager connection" "$default_host" "0" validate_host
  prompt_required central_host "Ops Manager central host or IP" "$default_host" "0" validate_host
  prompt_required opsman_port "Ops Manager HTTP port" "$DEFAULT_OPSMAN_PORT" "0" validate_port
  prompt_required admin_email "Ops Manager admin email" "$DEFAULT_ADMIN_EMAIL" "0" validate_email
  prompt_required from_email "Ops Manager from email" "$admin_email" "0" validate_email
  prompt_required reply_to_email "Ops Manager reply-to email" "$admin_email" "0" validate_email

  log "Starting minimal bootstrap. This can take several minutes."
  [[ "$DRY_RUN" == "1" ]] && log "DRY_RUN=1 is enabled. Commands will be printed but not executed."
  log "MongoDB AppDB will run as a standalone mongod for Ops Manager pre-flight compatibility."

  install_prerequisites
  configure_mongodb_repo
  install_mongodb
  write_mongod_config "$datadir" "$mongo_port"
  start_mongodb
  create_appdb_user "$mongo_user" "$mongo_password" "$mongo_port"
  install_ops_manager
  write_ops_manager_config "$mongo_user" "$mongo_password" "$appdb_host" "$mongo_port" "$central_host" "$opsman_port" "$admin_email" "$from_email" "$reply_to_email"
  start_ops_manager

  log "Bootstrap completed."
  log "Ops Manager URL: http://${central_host}:${opsman_port}"
}

main "$@"
