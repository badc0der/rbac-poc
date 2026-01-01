# ==============================================================================
# RBAC-POC Makefile (Ubuntu 24.04 / SELinux / systemd)
# - Paths mirror the Vagrant/VM layout prepared by provision.sh
# - Most targets are idempotent and safe to re-run.
# Usage:
#   make help
#   make env deps selinux-load start status logs
# ==============================================================================

SHELL := /bin/bash

# ----------------------------------------------------------------------
# Paths (override with: make RBAC_DIR=/some/where)
# ----------------------------------------------------------------------
RBAC_DIR ?= /opt/rbac-poc
BIN_DIR  := $(RBAC_DIR)/bin
ART_DIR  := $(RBAC_DIR)/artefacts
LOG_DIR  := $(RBAC_DIR)/logs
VENV     := $(RBAC_DIR)/venv
SVC_DIR  := /etc/systemd/system

# ----------------------------------------------------------------------
# Services & SELinux modules
# ----------------------------------------------------------------------
SERVICES := rbac-trace-setup.service rbac-rules.service rbac-ml.service

# Any .cil files you drop under $(RBAC_DIR)/selinux will be loaded
CIL_DIR  := $(RBAC_DIR)/selinux
# Optionally specify explicit module names to remove (no suffix)
CIL_MODULES ?=

# ----------------------------------------------------------------------
# Python deps (align with provision.sh)
# ----------------------------------------------------------------------
REQ_TXT := $(RBAC_DIR)/requirements.txt

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------
.PHONY: help
help:
	@echo "RBAC-POC — common tasks"
	@echo
	@echo "Environment:"
	@echo "  make env           # create venv        ($(VENV))"
	@echo "  make deps          # pip install deps   ($(REQ_TXT))"
	@echo
	@echo "SELinux:"
	@echo "  make selinux-status   # show current SELinux mode"
	@echo "  make selinux-load     # load all CILs from $(CIL_DIR)"
	@echo "  make selinux-unload   # remove modules in CIL_MODULES=…"
	@echo
	@echo "Tracing:"
	@echo "  make ftrace-setup  # run TraceFS one-shot setup"
	@echo "  make trace-test    # quick read test of trace_pipe"
	@echo
	@echo "Services:"
	@echo "  make start stop restart enable disable status"
	@echo "  make logs          # recent combined logs"
	@echo "  make tail          # follow runtime logs"
	@echo
	@echo "One-off runs:"
	@echo "  make rules-once    # run rules daemon in foreground"
	@echo "  make model-once    # run model daemon in foreground"
	@echo "  make smoke         # minimal feature-collector smoke test"
	@echo
	@echo "Maintenance:"
	@echo "  make clean-cache   # clear pip & __pycache__"
	@echo "  make package       # tarball selected artefacts/scripts"
	@echo
	@echo "Variables (override via CLI):"
	@echo "  RBAC_DIR=$(RBAC_DIR)"
	@echo "  CIL_MODULES='encryption_rbac_base encryption_rules encryption_block'"

# ----------------------------------------------------------------------
# Environment & deps
# ----------------------------------------------------------------------
.PHONY: env
env:
	@test -d "$(VENV)" || python3 -m venv "$(VENV)"
	@echo "venv ready: $(VENV)"

$(REQ_TXT):
	@printf "%s\n" \
	"pandas>=2.2" \
	"numpy>=1.26" \
	"scikit-learn>=1.4" \
	"joblib>=1.3" \
	"psutil>=5.9" \
	"networkx>=3.2" \
	"xgboost>=2.0" \
	"tqdm>=4.66" > "$(REQ_TXT)"

.PHONY: deps
deps: env $(REQ_TXT)
	@"$(VENV)/bin/pip" install --upgrade pip wheel setuptools
	@"$(VENV)/bin/pip" install -r "$(REQ_TXT)"

# ----------------------------------------------------------------------
# SELinux helpers
# ----------------------------------------------------------------------
.PHONY: selinux-status
selinux-status:
	@echo "=== SELinux status ==="
	@getenforce || true
	@selinuxenabled && echo "enabled" || echo "disabled"
	@echo "Config: /etc/selinux/config"
	@echo "Loaded modules:"
	@semodule -l | sort | sed 's/^/  /'

.PHONY: selinux-load
selinux-load:
	@test -d "$(CIL_DIR)" || mkdir -p "$(CIL_DIR)"
	@shopt -s nullglob; \
	for cil in "$(CIL_DIR)"/*.cil; do \
	  echo "semodule -i $$cil"; sudo semodule -i "$$cil"; \
	done; \
	shopt -u nullglob
	@echo "Loaded CILs from $(CIL_DIR)."

.PHONY: selinux-unload
selinux-unload:
	@if [ -z "$(CIL_MODULES)" ]; then \
	  echo "CIL_MODULES is empty; nothing to remove."; \
	else \
	  for m in $(CIL_MODULES); do \
	    echo "semodule -r $$m || true"; \
	    sudo semodule -r "$$m" || true; \
	  done; \
	fi

# ----------------------------------------------------------------------
# TraceFS
# ----------------------------------------------------------------------
.PHONY: ftrace-setup
ftrace-setup:
	@sudo "$(BIN_DIR)/ftrace-setup.sh"

.PHONY: trace-test
trace-test:
	@sudo -u rbac bash -c 'head -n 5 /sys/kernel/tracing/trace_pipe || true'

# ----------------------------------------------------------------------
# Services
# ----------------------------------------------------------------------
.PHONY: start stop restart enable disable status
start:
	@sudo systemctl start $(SERVICES)

stop:
	@sudo systemctl stop $(SERVICES)

restart:
	@sudo systemctl restart $(SERVICES)

enable:
	@sudo systemctl enable $(SERVICES)

disable:
	@sudo systemctl disable $(SERVICES) || true

status:
	@systemctl status $(SERVICES) --no-pager || true

.PHONY: logs tail
logs:
	@journalctl -u rbac-trace-setup -u rbac-rules -u rbac-ml -n 200 --no-pager || true

tail:
	@journalctl -u rbac-rules -u rbac-ml -f

# ----------------------------------------------------------------------
# One-off foreground runs (helpful for debugging)
# ----------------------------------------------------------------------
RULES_CMD = "$(VENV)/bin/python" "$(BIN_DIR)/rules_daemon.py" \
            --rules "$(ART_DIR)/rules.json" \
            --keys  "$(ART_DIR)/ftrace_keys.json" \
            --csv   "$(LOG_DIR)/decisions_rules.csv" \
            --log   "$(LOG_DIR)/rules_daemon.log" \
            --penc-threshold 0.50

MODEL_CMD = "$(VENV)/bin/python" "$(BIN_DIR)/model_daemon.py" \
            --model "$(ART_DIR)/best_model.joblib" \
            --preproc "$(ART_DIR)/preprocessor.joblib" \
            --feature-order "$(ART_DIR)/feature_order.json" \
            --keys "$(ART_DIR)/ftrace_keys.json" \
            --csv  "$(LOG_DIR)/decisions_ml.csv" \
            --block-threshold 0.50 --period 1.0

.PHONY: rules-once
rules-once:
	@sudo -u rbac bash -lc '$(RULES_CMD)'

.PHONY: model-once
model-once:
	@sudo -u rbac bash -lc '$(MODEL_CMD)'

# ----------------------------------------------------------------------
# Smoke test: verify artefacts loadable and ftrace keys parse
# ----------------------------------------------------------------------
.PHONY: smoke
smoke:
	@echo "[smoke] Joblib artefacts…"
	@sudo -u rbac "$(VENV)/bin/python" - <<'PY'
import joblib, json, pathlib
print(" sklearn import OK")
joblib.load("$(ART_DIR)/preprocessor.joblib")
joblib.load("$(ART_DIR)/best_model.joblib")
fo = json.loads(pathlib.Path("$(ART_DIR)/feature_order.json").read_text())
print(" feature_order:", len(fo), "features")
print(" OK: artefacts loadable")
PY
	@echo "[smoke] ftrace keys parse…"
	@sudo -u rbac "$(VENV)/bin/python" - <<'PY'
import json, re, pathlib
txt = pathlib.Path("$(ART_DIR)/ftrace_keys.json").read_text()
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
print(" keys:", len(syms))
print(" sample:", sorted(list(syms))[:5])
PY
	@echo "[smoke] trace read (5 lines)…"
	@sudo -u rbac bash -lc 'head -n 5 /sys/kernel/tracing/trace_pipe || true'
	@echo "[smoke] done."

# ----------------------------------------------------------------------
# Maintenance
# ----------------------------------------------------------------------
.PHONY: clean-cache
clean-cache:
	@find "$(RBAC_DIR)" -type d -name "__pycache__" -print0 | xargs -0 rm -rf || true
	@"$(VENV)/bin/pip" cache purge || true

.PHONY: package
package:
	@mkdir -p "$(RBAC_DIR)/dist"
	@tar -C / -czf "$(RBAC_DIR)/dist/rbac-poc_$(shell date +%Y%m%d_%H%M).tar.gz" \
	  opt/rbac-poc/bin \
	  opt/rbac-poc/artefacts \
	  opt/rbac-poc/requirements.txt \
	  etc/systemd/system/rbac-ml.service \
	  etc/systemd/system/rbac-rules.service \
	  etc/systemd/system/rbac-trace-setup.service
	@echo "Created: $(RBAC_DIR)/dist"

# Default target
.DEFAULT_GOAL := help
