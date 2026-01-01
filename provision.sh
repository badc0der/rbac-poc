#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# RBAC-POC provisioner for Ubuntu 24.04 (Noble)
# - Installs SELinux toolchain + deps
# - Preps Python venv and systemd units
# - Sets up tracefs access for 'rbac' service user
# Notes:
# * First boot may need a reboot to bring SELinux into enforcing mode.
# * This script is idempotent; safe to re-run.
# ------------------------------------------------------------------------------

log() { printf "\n\033[1;32m[provision]\033[0m %s\n" "$*"; }

export DEBIAN_FRONTEND=noninteractive

log "Updating APT and installing base packages…"
apt-get update -y
apt-get install -y \
  # SELinux base
  selinux-basics selinux-policy-default selinux-utils policycoreutils \
  policycoreutils-python-utils setools setools-console checkpolicy secilc \
  auditd \
  # Build & Python
  build-essential python3-venv python3-pip python3-dev \
  # Utils
  git curl wget make jq unzip vim-tiny pkg-config

log "Ensuring auditd is enabled…"
systemctl enable --now auditd || true

# ------------------------------------------------------------------------------
# SELinux activation (Ubuntu ships AppArmor by default; SELinux can co-exist)
# ------------------------------------------------------------------------------

# Enable SELinux if not already. selinux-activate will:
#  - install base config under /etc/selinux
#  - set SELINUX=permissive by default
if ! command -v selinuxenabled >/dev/null 2>&1; then
  log "SELinux tools not on PATH? (unexpected). Continuing."
fi

if [ ! -f /etc/selinux/config ]; then
  log "Activating SELinux (first-time)…"
  selinux-activate || true
fi

# Ensure kernel cmdline has selinux=1 security=selinux (idempotent)
if [ -f /etc/default/grub ]; then
  if ! grep -q 'selinux=1' /etc/default/grub; then
    log "Appending SELinux kernel params to GRUB_CMDLINE_LINUX…"
    sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 selinux=1 security=selinux"/' /etc/default/grub || true
    sed -i 's/^\(GRUB_CMDLINE_LINUX="[^"]*\)"/\1 selinux=1 security=selinux"/' /etc/default/grub || true
    update-grub || true
  fi
fi

# Set SELinux enforcing by default
if [ -f /etc/selinux/config ]; then
  sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
  sed -i 's/^SELINUXTYPE=.*/SELINUXTYPE=default/' /etc/selinux/config
fi

# If currently disabled, inform user to reboot later.
SEL_STATUS="unknown"
if selinuxenabled 2>/dev/null; then
  SEL_STATUS="enabled"
else
  SEL_STATUS="disabled"
fi
log "SELinux status (pre-reboot): ${SEL_STATUS}"

# ------------------------------------------------------------------------------
# Project layout and service account
# ------------------------------------------------------------------------------

RBAC_DIR="/opt/rbac-poc"
BIN_DIR="${RBAC_DIR}/bin"
ART_DIR="${RBAC_DIR}/artefacts"
LOG_DIR="${RBAC_DIR}/logs"
SVC_DIR="/etc/systemd/system"

log "Creating project directories…"
mkdir -p "${BIN_DIR}" "${ART_DIR}" "${LOG_DIR}" "${RBAC_DIR}/selinux"

# Service user 'rbac' (no shell, locked)
if ! id -u rbac >/dev/null 2>&1; then
  log "Creating service account 'rbac'…"
  useradd --system --home "${RBAC_DIR}" --create-home --shell /usr/sbin/nologin rbac
fi

log "Fixing ownership and permissions…"
chown -R rbac:rbac "${RBAC_DIR}"
chmod 0750 "${BIN_DIR}"
chmod 0755 "${RBAC_DIR}" "${ART_DIR}" "${LOG_DIR}"

# ------------------------------------------------------------------------------
# Python virtual environment
# ------------------------------------------------------------------------------

if [ ! -d "${RBAC_DIR}/venv" ]; then
  log "Creating Python venv…"
  python3 -m venv "${RBAC_DIR}/venv"
fi

log "Installing Python runtime dependencies in venv…"
# We keep versions modern for Py3.12 while maintaining compatibility with .joblib artefacts.
# If you need to pin to older sklearn, do it per your artefact matrix.
"${RBAC_DIR}/venv/bin/pip" install --upgrade pip wheel setuptools

REQ_TXT="${RBAC_DIR}/requirements.txt"
cat > "${REQ_TXT}" <<'REQS'
# Core
pandas>=2.2
numpy>=1.26
scikit-learn>=1.4
joblib>=1.3
psutil>=5.9
networkx>=3.2
xgboost>=2.0
# Logging/CLI
tqdm>=4.66
REQS

"${RBAC_DIR}/venv/bin/pip" install -r "${REQ_TXT}"

# ------------------------------------------------------------------------------
# TraceFS helper: ftrace-setup.sh (only create if missing)
# ------------------------------------------------------------------------------

if [ ! -f "${BIN_DIR}/ftrace-setup.sh" ]; then
  log "Installing minimal ftrace-setup.sh…"
  cat > "${BIN_DIR}/ftrace-setup.sh" <<'FTRACE'
#!/usr/bin/env bash
set -euo pipefail

TRACE=/sys/kernel/tracing
FG="${TRACE}/current_tracer"
EVENTS="${TRACE}/set_ftrace_filter"
PIPE="${TRACE}/trace_pipe"

# Require root
if [ "$EUID" -ne 0 ]; then
  echo "Run as root" >&2; exit 1
fi

# Select function_graph tracer and filter to a conservative symbol set if provided
echo nop > "${TRACE}/tracing_on" || true
echo function_graph > "${FG}"

# Optional filter file shipped with artefacts (one symbol per line)
KEYS="/opt/rbac-poc/artefacts/ftrace_keys.json"
if [ -f "${KEYS}" ]; then
  # Accept JSON array or YAML-ish list; strip crud
  TMP=$(mktemp)
  python3 - "$KEYS" > "$TMP" <<'PY'
import json, re, sys, pathlib
txt = pathlib.Path(sys.argv[1]).read_text()
syms=set()
try:
    data=json.loads(txt)
    if isinstance(data,list):
        syms|={str(x).strip() for x in data}
except Exception:
    for ln in txt.splitlines():
        ln=ln.strip()
        if not ln or ln.startswith("#"): continue
        if ln.startswith("-"): ln=ln[1:].strip()
        ln=re.sub(r'^[\'"]|[\'"],?$',"",ln)
        if ln: syms.add(ln)
for s in sorted(syms):
    print(s)
PY
  cat "$TMP" > "${EVENTS}"
  rm -f "$TMP"
fi

# Allow 'rbac' user to read trace_pipe
chgrp rbac "${PIPE}" || true
chmod g+r "${PIPE}" || true

# Start tracing
echo 1 > "${TRACE}/options/funcgraph-abstime" || true
echo 1 > "${TRACE}/tracing_on"
echo "TraceFS is ready."
FTRACE
  chmod 0750 "${BIN_DIR}/ftrace-setup.sh"
  chown rbac:rbac "${BIN_DIR}/ftrace-setup.sh"
fi

# ------------------------------------------------------------------------------
# Systemd unit files
# ------------------------------------------------------------------------------

log "Installing systemd units…"

# 1) Trace setup service (runs once at boot to prep tracefs)
cat > "${SVC_DIR}/rbac-trace-setup.service" <<UNIT
[Unit]
Description=RBAC-POC TraceFS Setup
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
ExecStart=${BIN_DIR}/ftrace-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# 2) Rules daemon (assumes rules_daemon.py is in /opt/rbac-poc/bin)
cat > "${SVC_DIR}/rbac-rules.service" <<UNIT
[Unit]
Description=RBAC-POC Rules Detector
After=rbac-trace-setup.service
Wants=rbac-trace-setup.service

[Service]
Type=simple
User=rbac
Group=rbac
WorkingDirectory=${RBAC_DIR}
ExecStart=${RBAC_DIR}/venv/bin/python ${BIN_DIR}/rules_daemon.py \\
  --rules ${ART_DIR}/rules.json \\
  --keys  ${ART_DIR}/ftrace_keys.json \\
  --csv   ${LOG_DIR}/decisions_rules.csv \\
  --log   ${LOG_DIR}/rules_daemon.log \\
  --penc-threshold 0.50
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

# 3) Model daemon (assumes model_daemon.py + artefacts)
cat > "${SVC_DIR}/rbac-ml.service" <<UNIT
[Unit]
Description=RBAC-POC ML Detector
After=rbac-trace-setup.service
Wants=rbac-trace-setup.service

[Service]
Type=simple
User=rbac
Group=rbac
WorkingDirectory=${RBAC_DIR}
ExecStart=${RBAC_DIR}/venv/bin/python ${BIN_DIR}/model_daemon.py \\
  --model ${ART_DIR}/best_model.joblib \\
  --preproc ${ART_DIR}/preprocessor.joblib \\
  --feature-order ${ART_DIR}/feature_order.json \\
  --keys ${ART_DIR}/ftrace_keys.json \\
  --csv  ${LOG_DIR}/decisions_ml.csv \\
  --block-threshold 0.50 --period 1.0
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

# ------------------------------------------------------------------------------
# Optional: install SELinux CIL modules if present
# ------------------------------------------------------------------------------

if compgen -G "${RBAC_DIR}/selinux/*.cil" >/dev/null; then
  log "Found CIL modules in ${RBAC_DIR}/selinux; attempting to load…"
  for cil in "${RBAC_DIR}"/selinux/*.cil; do
    log "  semodule -i ${cil}"
    semodule -i "${cil}" || true
  done
else
  log "No local CILs found under ${RBAC_DIR}/selinux (this is fine)."
fi

# ------------------------------------------------------------------------------
# TraceFS, services: enable but do not fail if SELinux needs reboot
# ------------------------------------------------------------------------------

log "Enabling services…"
systemctl enable rbac-trace-setup.service rbac-rules.service rbac-ml.service || true

# ------------------------------------------------------------------------------
# Final messages
# ------------------------------------------------------------------------------

echo ""
echo "===================================================================="
echo " Provisioning complete."
echo ""
echo "  Project directory : ${RBAC_DIR}"
echo "  Service user      : rbac"
echo ""
if [ "${SEL_STATUS}" != "enabled" ]; then
  echo "  SELinux appears DISABLED in current boot."
  echo "  -> Please reboot the VM to apply kernel cmdline and enforcing mode."
fi
echo ""
echo " Next steps (inside the VM):"
echo "   $ sudo systemctl start rbac-trace-setup.service"
echo "   $ sudo systemctl start rbac-rules.service rbac-ml.service"
echo "   # Logs:"
echo "   $ journalctl -u rbac-trace-setup -u rbac-rules -u rbac-ml -f"
echo "===================================================================="
