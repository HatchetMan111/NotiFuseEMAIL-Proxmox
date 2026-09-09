#!/usr/bin/env bash
# =============================================================================
# Notifuse LXC Installer — Proxmox VE Community-Scripts style
# Source app: https://github.com/Notifuse/notifuse
#
# One-liner (run on the Proxmox host as root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NotiFuseEMAIL-Proxmox/main/install/notifuse.sh)"
#
# Modes (auto-detected):
#   1. Proxmox host      -> creates LXC (Debian 13), pushes this script, triggers install
#   2. Inside LXC (new)  -> installs Notifuse + PostgreSQL 17 + systemd service
#   3. Inside LXC (existing, --update) -> updates Notifuse to latest release
#
# Idempotent: safe to re-run. App runs fully local, no cloud services required.
# Debug: full log at /var/log/notifuse-install.log; on failure the complete
#        error chain (command, exit code, line, journalctl) is printed.
#        For a full trace re-run with: bash -x notifuse.sh
# =============================================================================
set -Eeuo pipefail

# Debian LXC templates ship without any UTF-8 locale (LANG=en_US.UTF-8 unset) —
# that spams every perl/psql/node call with "Setting locale failed" warnings.
# C.UTF-8 is built into glibc, needs no locales package, and silences them.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# -----------------------------------------------------------------------------
# Variables (override while invoking, e.g. CT_ID=305 APP_PORT=8080 bash ...)
# -----------------------------------------------------------------------------
APP="Notifuse"
APP_LOWER="notifuse"
APP_REPO="Notifuse/notifuse"                          # upstream GitHub repo (source tarball)
APP_PORT="${APP_PORT:-8080}"                          # web UI port, binds 0.0.0.0
APP_DATA_DIR="/opt/${APP_LOWER}"                      # install dir inside the CT

# URL of THIS script on GitHub (HatchetMan111/NotiFuseEMAIL-Proxmox placeholder — must be replaced after fork)
SCRIPT_URL_RAW="${SCRIPT_URL_RAW:-https://raw.githubusercontent.com/HatchetMan111/NotiFuseEMAIL-Proxmox/main/install/notifuse.sh}"
# base of the fork's raw "main" branch (derived: .../main/install/x.sh -> .../main/)
REPO_RAW_BASE="${SCRIPT_URL_RAW%install/*}"

CT_ID="${CT_ID:-}"                                    # empty = reuse notifuse CT by name, else next free ID
CT_NAME="${CT_NAME:-notifuse}"
CT_CPU="${CT_CPU:-2}"
CT_RAM="${CT_RAM:-4096}"                              # MiB (React build needs headroom)
CT_SWAP="${CT_SWAP:-4096}"
CT_DISK="${CT_DISK:-12}"                              # GiB
CT_VERSION="${CT_VERSION:-13}"                        # Debian 13
CT_TEMPLATE="${CT_TEMPLATE:-}"                         # empty = auto (pveam download if missing)
CT_STORAGE="${CT_STORAGE:-}"                          # empty = auto (local-lvm -> local -> first rootdir)
CT_UNPRIVILEGED="${CT_UNPRIVILEGED:-1}"
CT_ONBOOT=1
NET_BRIDGE="${NET_BRIDGE:-vmbr0}"

DB_NAME="${DB_NAME:-notifuse_system}"
DB_USER="${DB_USER:-notifuse}"
DB_HOST="127.0.0.1"
DB_PORT="5432"

LOG_FILE="/var/log/notifuse-install.log"

# -----------------------------------------------------------------------------
# Colors / helpers (community-scripts look & feel)
# -----------------------------------------------------------------------------
YW=$(printf '\033[33m'); RD=$(printf '\033[31m'); GN=$(printf '\033[32m')
BOLD=$(printf '\033[1m'); BGN=$(printf '\033[4;92m'); CL=$(printf '\033[0m')
INFO="${YW}[INFO]${CL} "; OK="${GN}[ OK ]${CL} "; ERROR="${RD}[FAIL]${CL} "
GATEWAY="${BGN}[http]${CL}"

msg_info() { echo -e "${INFO}${YW}${1}${CL}"; }
msg_ok()   { echo -e "${OK}${GN}${1}${CL}"; }
msg_error(){ echo -e "${ERROR}${RD}${1}${CL}" >&2; }

header_info() {
  clear 2>/dev/null || true
  cat <<EOF
${YW}
  ┌───────────────────────────────────────────────────────────────┐
  │  ${BOLD}Notifuse — Proxmox VE LXC Installer${CL}${YW}                           │
  │  Self-hosted newsletter & transactional email platform         │
  │  Community-Scripts style · GitHub-first · fully local         │
  └───────────────────────────────────────────────────────────────┘
${CL}
EOF
}

# -----------------------------------------------------------------------------
# Error handling: print the COMPLETE error chain, never just the last line.
# -----------------------------------------------------------------------------
on_error() {
  local exit_code=$?
  local cmd="$BASH_COMMAND"
  local line=${BASH_LINENO[0]}
  local fn="${FUNCNAME[1]:-main}"
  echo -e "${ERROR}${RD}══════════════════════════════════════════════════════════════${CL}" >&2
  msg_error "Command failed : ${RD}${cmd}${CL}"
  msg_error "Exit code     : ${RD}${exit_code}${CL}"
  msg_error "Location      : ${RD}line ${line} in function ${fn} (${0})${CL}"
  echo -e "${ERROR}${RD}────────────────────────────────────────────────────────────────${CL}" >&2
  if [[ "${MODE:-}" != "host" ]] && [[ -d /run/systemd/system ]]; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^${APP_LOWER}.service"; then
      msg_error "--- systemctl status ${APP_LOWER} ---"
      systemctl status "${APP_LOWER}" --no-pager -l >&2 || true
      msg_error "--- journalctl -u ${APP_LOWER} (last 80 lines) ---"
      journalctl -u "${APP_LOWER}" -n 80 --no-pager >&2 || true
    fi
    msg_error "--- journalctl -u postgresql (last 20 lines) ---"
    journalctl -u postgresql -n 20 --no-pager >&2 || true
  fi
  msg_error "Full install log : ${LOG_FILE}"
  if [[ -f "${0}" ]]; then
    msg_error "Trace re-run      : bash -x ${0}"
  else
    msg_error "Trace re-run      : bash -x <(wget -qO- ${SCRIPT_URL_RAW})"
  fi
  msg_error "══════════════════════════════════════════════════════════════"
  exit "$exit_code"
}
trap on_error ERR
trap 'sleep 1' EXIT   # give the tee process substitution time to flush

STD() { "$@" >/dev/null 2>&1; }  # run quiet, keep exit code (set -e still applies)

[[ "${EUID}" -eq 0 ]] || { msg_error "Run as root."; exit 1; }

# Log everything (stdout+stderr) to LOG_FILE and console
exec > >(tee -a "${LOG_FILE}") 2>&1

header_info

# =============================================================================
# MODE DETECTION
# =============================================================================
if [[ -d /etc/pve ]] && command -v pct >/dev/null 2>&1; then
  MODE="host"
elif [[ -f /etc/os-release ]] && grep -qi debian /etc/os-release; then
  MODE="container"
else
  msg_error "Unsupported environment: run on a Proxmox host or inside the Debian LXC."
  exit 1
fi

if [[ "${1:-}" == "--update" ]]; then
  [[ "${MODE}" == "container" ]] || { msg_error "--update only inside the LXC: pct exec <ctid> -- bash /root/notifuse.sh --update"; exit 1; }
  MODE="update"
fi

msg_info "Detected mode: ${BOLD}${MODE}${CL}"

# =============================================================================
# MODE: inside the container (install / update)
# =============================================================================
if [[ "${MODE}" != "host" ]]; then

  dl() {  # download with retry; on failure print HTTP code for the full chain
    local url="$1" dest="$2"
    msg_info "Downloading ${url}"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$dest" "$url" || {
      msg_error "Download failed (HTTP check follows):"
      curl -sSL --max-time 15 -o /dev/null -w 'HTTP %{http_code} for %{url_effective}\n' "$url" || true
      return 1
    }
  }

  github_latest() {
    # NOTE: single trailing "|| true" only — a mid-pipeline "||" would bind
    # tighter than intended (cmd || (true | next)) and skip the rest on success.
    curl -fsSL --retry 3 "https://api.github.com/repos/${APP_REPO}/releases/latest" 2>/dev/null \
      | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      | head -1 || true
  }

  psql_root() {  # run psql as postgres system user
    runuser -u postgres -- psql -tAX -v ON_ERROR_STOP=1 "$@"
  }

  verify_stack() {  # service active + listening on 0.0.0.0 + HTTP /healthz
    msg_info "Verifying systemd service ..."
    sleep 3
    if ! systemctl is-active --quiet "${APP_LOWER}"; then
      msg_error "Service not active:"
      systemctl status "${APP_LOWER}" --no-pager -l >&2 || true
      journalctl -u "${APP_LOWER}" -n 80 --no-pager >&2 || true
      return 1
    fi
    msg_ok "Service active (systemctl is-active ${APP_LOWER})"

    if ! ss -tln | grep -Eq "0\.0\.0\.0:${APP_PORT}|\\*:${APP_PORT}"; then
      msg_error "Port ${APP_PORT} not listening on 0.0.0.0:"
      ss -tlnp >&2 || true
      journalctl -u "${APP_LOWER}" -n 80 --no-pager >&2 || true
      return 1
    fi
    msg_ok "Listening on 0.0.0.0:${APP_PORT}"

    msg_info "Verifying web UI (HTTP GET /healthz) ..."
    local http_code=""
    for _ in $(seq 1 30); do
      http_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${APP_PORT}/healthz" || true)
      [[ "$http_code" == "200" ]] && break
      sleep 2
    done
    if [[ "$http_code" != "200" ]]; then
      msg_error "HTTP check failed (last status: ${http_code:-none})"
      journalctl -u "${APP_LOWER}" -n 80 --no-pager >&2 || true
      return 1
    fi
    msg_ok "Web UI healthy (GET /healthz -> HTTP ${http_code})"
  }

  # ---------------------------------------------------------------------------
  container_install() {
    export DEBIAN_FRONTEND=noninteractive

    msg_info "Updating container OS ..."
    STD apt-get update
    STD apt-get -y upgrade
    STD apt-get -y install --no-install-recommends \
      ca-certificates curl gnupg openssl git wget logrotate unzip

    # firewall (usually inactive in fresh LXC; open port if present)
    if command -v ufw >/dev/null 2>&1; then STD ufw allow "${APP_PORT}/tcp" || true; fi

    # --- PostgreSQL 17 (pgdg, fallback to distro postgres) --------------------
    if ! command -v psql >/dev/null 2>&1; then
      msg_info "Installing PostgreSQL 17 ..."
      curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /etc/apt/trusted.gpg.d/pgdg.asc
      echo "deb http://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "$VERSION_CODENAME")-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
      STD apt-get update
      STD apt-get -y install --no-install-recommends postgresql-17 \
        || STD apt-get -y install --no-install-recommends postgresql
    fi
    STD systemctl enable --now postgresql

    # --- database role + db (idempotent) ---------------------------------------
    DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
    if [[ -f "${APP_DATA_DIR}/.env" ]]; then
      msg_info ".env already exists — keeping secrets"
    else
      msg_info "Provisioning database role '${DB_USER}' and database '${DB_NAME}'"
      if psql_root -c "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
        psql_root -c "ALTER ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}' CREATEDB;"
      else
        psql_root -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}' CREATEDB;"
      fi
      if ! psql_root -c "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
        psql_root -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
      fi
    fi

    # --- Go (build dependency, removed again at the end) ------------------------
    if [[ ! -x /usr/local/go/bin/go ]]; then
      GO_VERSION="$(curl -fsSL --retry 3 'https://go.dev/VERSION?m=text' 2>/dev/null | head -n1 || true)"
      msg_info "Installing Go ${GO_VERSION} ..."
      dl "https://go.dev/dl/${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" /tmp/go.tgz
      tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
    fi
    export PATH="/usr/local/go/bin:${PATH}"

    # --- Node.js 22 (frontend build dependency) ----------------------------------
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | cut -d. -f1 | tr -d v)" -lt 22 ]]; then
      msg_info "Installing Node.js 22 (NodeSource) ..."
      curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource.sh
      STD bash /tmp/nodesource.sh
      STD apt-get install -y nodejs
    fi

    # --- Notifuse source (release tarball) ----------------------------------------
    local RELEASE_TAG SRC_DIR
    RELEASE_TAG="$(github_latest)"
    [[ -n "${RELEASE_TAG}" ]] || { msg_error "Could not resolve latest release of ${APP_REPO}"; return 1; }
    msg_info "Fetching Notifuse ${RELEASE_TAG} (source tarball)"
    SRC_DIR="${APP_DATA_DIR}/src"
    rm -rf "${SRC_DIR}"
    mkdir -p "${SRC_DIR}"
    dl "https://github.com/${APP_REPO}/archive/${RELEASE_TAG}.tar.gz" /tmp/notifuse.tar.gz
    tar -xzf /tmp/notifuse.tar.gz -C "${SRC_DIR}" --strip-components=1
    rm -f /tmp/notifuse.tar.gz
    echo "${RELEASE_TAG}" > "${APP_DATA_DIR}/version"

    # --- build frontends -------------------------------------------------------------
    for FE in console notification_center web_analytics_sdk; do
      msg_info "Building frontend: ${FE}"
      cd "${SRC_DIR}/${FE}"
      npm config set fetch-retries 5
      npm config set fetch-retry-mintimeout 20000
      npm config set fetch-retry-maxtimeout 120000
      STD npm ci
      STD npm run build
    done

    # --- build Go backend ---------------------------------------------------------------
    msg_info "Building notifuse-server (Go) ..."
    cd "${SRC_DIR}"
    export CGO_ENABLED=0
    STD go build -ldflags="-s -w" -o "${APP_DATA_DIR}/notifuse-server" ./cmd/api
    msg_ok "Built ${APP_DATA_DIR}/notifuse-server"

    # --- runtime layout ----------------------------------------------------------------------
    mkdir -p "${APP_DATA_DIR}"/{console/dist,notification_center/dist,web_analytics_sdk/dist,data,geoip}
    cp -r "${SRC_DIR}/console/dist/."             "${APP_DATA_DIR}/console/dist/"
    cp -r "${SRC_DIR}/notification_center/dist/."  "${APP_DATA_DIR}/notification_center/dist/"
    cp "${SRC_DIR}/web_analytics_sdk/dist/notifuse-analytics.min.js" \
       "${APP_DATA_DIR}/web_analytics_sdk/dist/" 2>/dev/null || true
    [[ -f "${SRC_DIR}/data/GeoLite2-City.mmdb" ]] && cp "${SRC_DIR}/data/GeoLite2-City.mmdb" "${APP_DATA_DIR}/geoip/"

    # --- .env (only if missing — secrets survive updates) --------------------------------------
    if [[ ! -f "${APP_DATA_DIR}/.env" ]]; then
      msg_info "Generating secrets (SECRET_KEY, DB password) ..."
      SECRET_KEY="$(openssl rand -base64 48 | tr -d '\n')"
      cat > "${APP_DATA_DIR}/.env" <<ENV
SERVER_PORT=${APP_PORT}
SERVER_HOST=0.0.0.0
ENVIRONMENT=production
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
DB_SSLMODE=disable
SECRET_KEY=${SECRET_KEY}
ENV
    fi
    chmod 600 "${APP_DATA_DIR}/.env"

    # --- dedicated service user ------------------------------------------------------------
    if ! id "${APP_LOWER}" >/dev/null 2>&1; then
      useradd --system --home-dir "${APP_DATA_DIR}" --shell /usr/sbin/nologin "${APP_LOWER}"
    fi

    # --- systemd unit (GitHub-first: fetched from repo, heredoc fallback) ---------------
    msg_info "Installing systemd unit ..."
    UNIT_FILE="/etc/systemd/system/${APP_LOWER}.service"
    if curl -fsSL --retry 3 --connect-timeout 15 -o "${UNIT_FILE}" "${REPO_RAW_BASE}systemd/${APP_LOWER}.service" 2>/dev/null \
       && grep -q "^\[Service\]" "${UNIT_FILE}"; then
      msg_ok "systemd unit fetched from ${REPO_RAW_BASE}systemd/${APP_LOWER}.service"
    else
      msg_info "Falling back to embedded systemd unit"
      cat > "${UNIT_FILE}" <<UNIT
[Unit]
Description=Notifuse - self-hosted newsletter & email platform
Wants=network-online.target
After=network-online.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=${APP_LOWER}
Group=${APP_LOWER}
WorkingDirectory=${APP_DATA_DIR}
EnvironmentFile=${APP_DATA_DIR}/.env
ExecStart=${APP_DATA_DIR}/notifuse-server
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    fi

    chown -R "${APP_LOWER}:${APP_LOWER}" "${APP_DATA_DIR}"

    # --- clean build deps (runtime-only result; re-installed on --update) --------------------
    cd /
    msg_info "Removing build dependencies (Go, Node) ..."
    rm -rf "${SRC_DIR}" /root/.npm /root/.cache/go-build /usr/local/go /tmp/nodesource.sh
    STD apt-get -y purge nodejs
    STD apt-get -y autoremove --purge

    # --- start & verify --------------------------------------------------------------------------
    STD systemctl daemon-reload
    STD systemctl enable "${APP_LOWER}"
    STD systemctl restart "${APP_LOWER}"
    verify_stack || return 1

    local CT_IP
    CT_IP="$(hostname -I | awk '{print $1}')"
    msg_ok "Notifuse ${RELEASE_TAG} installed and verified."
    echo -e "${GATEWAY}${BGN}http://${CT_IP}:${APP_PORT}${CL}"
    echo -e "${GATEWAY}First run: open /setup and complete the wizard."
  }

  # ---------------------------------------------------------------------------
  container_update() {
    if [[ ! -x "${APP_DATA_DIR}/notifuse-server" ]]; then
      msg_error "No Notifuse installation found at ${APP_DATA_DIR} — run the install first."
      exit 1
    fi
    local current new
    current="$(cat "${APP_DATA_DIR}/version" 2>/dev/null || echo unknown)"
    new="$(github_latest)"
    [[ -n "${new}" ]] || { msg_error "Could not resolve latest release of ${APP_REPO}"; exit 1; }
    if [[ "${current}" == "${new}" ]]; then
      msg_ok "Already on ${current} — nothing to do."
      exit 0
    fi
    msg_info "Updating ${current} -> ${new}"
    msg_info "Stopping service (data and .env are preserved)"
    STD systemctl stop "${APP_LOWER}"

    cp -f "${APP_DATA_DIR}/.env" "${APP_DATA_DIR}/.env.bak"
    msg_ok "Secrets backed up: ${APP_DATA_DIR}/.env.bak"

    container_install   # rebuilds; keeps existing .env (secrets) and database

    rm -f "${APP_DATA_DIR}/.env.bak"
    msg_ok "Updated to ${new} and verified."
  }

  case "${MODE}" in
    update)    container_update ;;
    container)
      if [[ -x "${APP_DATA_DIR}/notifuse-server" ]]; then container_update
      else container_install; fi
      ;;
  esac
  exit 0
fi

# =============================================================================
# MODE: host — create/reuse the LXC, hand over to this same script
# =============================================================================

# --- CT ID resolution ---------------------------------------------------------
# Precedence: 1. existing CT with our hostname (idempotent reuse)
#             2. CT_ID if given AND free (or ours by name)
#             3. next free cluster ID — never collide with an occupied ID
next_free_id() {
  local id
  id="$(pvesh get /cluster/nextid 2>/dev/null || echo 100)"
  # bump until really free (protects against cluster race / stale nextid)
  while pct status "${id}" &>/dev/null; do
    id=$((id + 1))
  done
  echo "${id}"
}

ct_hostname() { pct list 2>/dev/null | awk -v i="$1" '$1==i {print $4; exit}' || true; }

EXISTING_CT="$(pct list 2>/dev/null | awk -v n="${CT_NAME}" '$4==n {print $1; exit}' || true)"
if [[ -n "${EXISTING_CT}" ]]; then
  CT_ID="${EXISTING_CT}"
  msg_info "CT '${CT_NAME}' already exists (ID ${CT_ID}) — reusing it (idempotent)"
elif [[ -n "${CT_ID}" ]] && pct status "${CT_ID}" &>/dev/null; then
  # explicitly requested ID is occupied by a DIFFERENT container -> next free
  msg_error "CT ID ${CT_ID} is already taken by '$(ct_hostname "${CT_ID}")' — using next free ID instead"
  CT_ID="$(next_free_id)"
  msg_info "Using CT ID ${CT_ID} (next free)"
elif [[ -n "${CT_ID}" ]]; then
  msg_info "Using CT ID ${CT_ID} (explicit, free)"
else
  CT_ID="$(next_free_id)"
  msg_info "Next free CT ID: ${CT_ID}"
fi

# --- LXC template -----------------------------------------------------------------
if [[ -z "${CT_TEMPLATE}" ]]; then
  avail="$(pveam list local 2>/dev/null | awk '{print $1}' | grep -E "debian-${CT_VERSION}-standard" | head -n1 || true)"
  if [[ -z "${avail}" ]]; then
    msg_info "Downloading Debian ${CT_VERSION} LXC template (pveam) ..."
    STD pveam update
    template_name="$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "debian-${CT_VERSION}-standard" | head -n1 || true)"
    [[ -n "${template_name}" ]] || { msg_error "No Debian ${CT_VERSION} template found via pveam available"; exit 1; }
    STD pveam download local "${template_name}"
    avail="local:vztmpl/${template_name}"
  fi
  CT_TEMPLATE="${avail}"
fi
msg_info "Template: ${CT_TEMPLATE}"

# --- storage: server-side verdict identical to the pct create check -----------------
# `pvesh ... --content rootdir` filters with the SAME parsed content hash that
# `pct create` validates ($scfg->{content}->{rootdir} in PVE/API2/LXC.pm).
# Client-side string matching is NOT sufficient: a storage may list rootdir in
# its content string while the plugin-validated hash lacks it (then pct create
# fails with "does not support container directories").
# Preference: local-lvm (battle-tested default) > local > non-shared > anything.
# Storages without enough free space for CT_DISK (+2 GiB margin) are skipped.
if [[ -z "${CT_STORAGE}" ]]; then
  NODE_NAME="$(hostname)"
  CT_STORAGE=""
  NEED_GB=$((CT_DISK + 2))
  NEED_BYTES=$((NEED_GB * 1024 * 1024 * 1024))
  STORAGE_JSON="$(pvesh get "/nodes/${NODE_NAME}/storage" --content rootdir --output-format json 2>/dev/null || true)"
  # name|content|avail|shared per storage object (flat JSON objects, no nesting)
  CANDIDATES="$(printf '%s' "${STORAGE_JSON}" \
    | grep -oE '\{[^{}]*\}' \
    | while IFS= read -r obj; do
        s="$(printf '%s' "$obj" | grep -oE '"storage"\s*:\s*"[^"]*"' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
        [[ -z "$s" ]] && continue
        c="$(printf '%s' "$obj" | grep -oE '"content"\s*:\s*"[^"]*"' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
        a="$(printf '%s' "$obj" | grep -oE '"avail"\s*:\s*[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
        sh="$(printf '%s' "$obj" | grep -oE '"shared"\s*:\s*[01]' | head -1 | grep -oE '[01]$' || true)"
        printf '%s|%s|%s|%s\n' "$s" "$c" "${a:-0}" "${sh:-0}"
      done || true)"
  for tier in local-lvm local NONSHARED ANY; do
    while IFS='|' read -r s c a sh; do
      [[ -z "$s" ]] && continue
      [[ "$c" == *rootdir* ]] || continue
      case "$tier" in
        local-lvm|local) [[ "$s" == "$tier" ]] || continue ;;
        NONSHARED) [[ "$sh" == "1" ]] && continue ;;
        ANY) : ;;
      esac
      if [[ -n "$a" && "$a" != "0" ]] && (( a < NEED_BYTES )); then
        msg_info "Storage '${s}' skipped: only $((a / 1024 / 1024 / 1024)) GiB free (< ${NEED_GB} GiB needed)"
        continue
      fi
      CT_STORAGE="$s"
      break 2
    done <<< "${CANDIDATES}"
  done
  if [[ -z "${CT_STORAGE}" ]]; then
    msg_error "No usable container storage (rootdir + ${NEED_GB} GiB free) found on node ${NODE_NAME}."
    msg_error "Set one explicitly, e.g.: CT_STORAGE=local-lvm bash -c \"\$(wget -qLO - ${SCRIPT_URL_RAW})\""
    msg_error "Server-side rootdir candidates were:"
    printf '%s\n' "${CANDIDATES}" | sed 's/^/  /' >&2 || true
    exit 1
  fi
  msg_info "Storage for LXC rootfs: ${CT_STORAGE}"
fi

# --- get this script as a file (one-liner pipes it via stdin — nothing to push) ----
SELF="/tmp/${APP_LOWER}-install.sh"
if wget -qO "${SELF}" "${SCRIPT_URL_RAW}" 2>/dev/null && [[ -s "${SELF}" ]]; then
  msg_info "Fetched installer from ${SCRIPT_URL_RAW}"
elif [[ -s "${0}" && -f "${0}" ]]; then
  cp "${0}" "${SELF}"
  msg_info "Using local copy of installer (${0})"
else
  msg_error "Could not fetch ${SCRIPT_URL_RAW} — check the URL / fork placeholder."
  exit 1
fi

# --- create or reuse CT ---------------------------------------------------------------
if pct status "${CT_ID}" &>/dev/null; then
  msg_info "CT ${CT_ID} exists — starting and running in-container installer (idempotent)"
  pct start "${CT_ID}" 2>/dev/null || true
else
  msg_info "Creating LXC ${CT_ID} (${CT_CPU} vCPU, $((CT_RAM/1024)) GiB RAM, ${CT_DISK} GiB disk, unprivileged=${CT_UNPRIVILEGED}) ..."
  pct create "${CT_ID}" "${CT_TEMPLATE}" \
    --hostname "${CT_NAME}" \
    --description "Notifuse - self-hosted newsletter & email platform (installed via ${SCRIPT_URL_RAW%%/install/*})" \
    --cores "${CT_CPU}" \
    --memory "${CT_RAM}" \
    --swap "${CT_SWAP}" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "name=eth0,bridge=${NET_BRIDGE},ip=dhcp" \
    --unprivileged "${CT_UNPRIVILEGED}" \
    --onboot "${CT_ONBOOT}" \
    --start 1
  msg_ok "LXC ${CT_ID} created and started"
fi

msg_info "Waiting for network (DHCP) ..."
CT_IP=""
for _ in $(seq 1 30); do
  CT_IP="$(pct exec "${CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP}" ]] && break
  sleep 2
done
[[ -n "${CT_IP}" ]] || { msg_error "No IP after 60s — check DHCP / bridge ${NET_BRIDGE}"; exit 1; }
msg_ok "Container IP: ${CT_IP}"

# --- push installer and run it inside the CT ---------------------------------------------
pct push "${CT_ID}" "${SELF}" "/root/${APP_LOWER}.sh" --perms 0755
msg_info "Running installer inside CT ${CT_ID} (this builds frontends + Go backend; takes a while) ..."
if ! pct exec "${CT_ID}" -- bash "/root/${APP_LOWER}.sh"; then
  msg_error "In-container installation failed."
  msg_error "Container log : pct exec ${CT_ID} -- tail -n 100 /var/log/notifuse-install.log"
  msg_error "Service status : pct exec ${CT_ID} -- systemctl status notifuse --no-pager -l"
  msg_error "App journal   : pct exec ${CT_ID} -- journalctl -u notifuse -n 100 --no-pager"
  msg_error "Trace re-run   : pct exec ${CT_ID} -- bash -x /root/notifuse.sh"
  exit 1
fi
msg_ok "In-container installation finished"

# --- verification from the HOST --------------------------------------------------------------
msg_info "Host-side verification (service + HTTP) ..."
ACTIVE="$(pct exec "${CT_ID}" -- systemctl is-active "${APP_LOWER}" 2>/dev/null | head -1 || echo unknown)"
[[ -z "${ACTIVE}" ]] && ACTIVE="unknown"
HTTP_CODE=""
for _ in $(seq 1 24); do
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${CT_IP}:${APP_PORT}/healthz" || echo 000)"
  [[ "${HTTP_CODE}" == "200" && "${ACTIVE}" == "active" ]] && break
  ACTIVE="$(pct exec "${CT_ID}" -- systemctl is-active "${APP_LOWER}" 2>/dev/null | head -1 || echo unknown)"
  [[ -z "${ACTIVE}" ]] && ACTIVE="unknown"
  sleep 5
done
if [[ "${HTTP_CODE}" != "200" || "${ACTIVE}" != "active" ]]; then
  msg_error "Verification failed: service=${ACTIVE}, HTTP /healthz=${HTTP_CODE}"
  pct exec "${CT_ID}" -- systemctl status "${APP_LOWER}" --no-pager -l >&2 || true
  pct exec "${CT_ID}" -- journalctl -u "${APP_LOWER}" -n 100 --no-pager >&2 || true
  exit 1
fi
msg_ok "service: ${ACTIVE} · HTTP GET /healthz -> ${HTTP_CODE} (from host via ${CT_IP})"

# --- reboot test (proof that onboot=1 + systemd bring everything back) -------------------------
msg_info "Reboot check: stopping and starting CT ${CT_ID} (full boot path incl. onboot) ..."
STD pct shutdown "${CT_ID}" --timeout 60
sleep 3
STD pct start "${CT_ID}"
sleep 5
HTTP_CODE_AFTER=""
for _ in $(seq 1 24); do
  HTTP_CODE_AFTER="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${CT_IP}:${APP_PORT}/healthz" || echo 000)"
  [[ "${HTTP_CODE_AFTER}" == "200" ]] && break
  sleep 5
done
if [[ "${HTTP_CODE_AFTER}" != "200" ]]; then
  msg_error "Reboot check failed: HTTP /healthz=${HTTP_CODE_AFTER}"
  pct exec "${CT_ID}" -- systemctl status "${APP_LOWER}" --no-pager -l >&2 || true
  pct exec "${CT_ID}" -- journalctl -u "${APP_LOWER}" -n 100 --no-pager >&2 || true
  exit 1
fi
msg_ok "Reboot test passed: Web UI back after reboot (HTTP ${HTTP_CODE_AFTER})"

rm -f "${SELF}"

echo
echo -e "${GATEWAY}${GN}${APP} installation complete and verified!${CL}"
echo -e "${GATEWAY}Web UI        : ${BGN}http://${CT_IP}:${APP_PORT}${CL}"
echo -e "${GATEWAY}Setup wizard  : ${BGN}http://${CT_IP}:${APP_PORT}/setup${CL}"
echo -e "${GATEWAY}Update later  : ${BGN}pct exec ${CT_ID} -- bash /root/${APP_LOWER}.sh --update${CL}"
echo -e "${GATEWAY}App logs      : ${BGN}pct exec ${CT_ID} -- journalctl -u ${APP_LOWER} -f${CL}"
echo -e "${GATEWAY}Install log   : ${BGN}pct exec ${CT_ID} -- tail -n 200 /var/log/notifuse-install.log${CL}"
