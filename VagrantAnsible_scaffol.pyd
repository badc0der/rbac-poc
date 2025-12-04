# This cell creates a reproducible Vagrant + Ansible scaffold for
# "Cuckoo v3.2 + GBDT post-processor" and packages it as a zip file.
# It does not fetch external code or malware—only the scaffolding.
import os, json, textwrap, zipfile, pathlib, shutil

root = pathlib.Path("/mnt/data/cuckoo-gbdt-baseline")
if root.exists():
    shutil.rmtree(root)
(root / "ansible" / "roles" / "cuckoo-host" / "tasks").mkdir(parents=True, exist_ok=True)
(root / "ansible" / "roles" / "cuckoo-host" / "templates").mkdir(parents=True, exist_ok=True)
(root / "ansible" / "roles" / "gbdt-postproc" / "tasks").mkdir(parents=True, exist_ok=True)
(root / "ansible" / "roles" / "gbdt-postproc" / "files").mkdir(parents=True, exist_ok=True)
(root / "scripts").mkdir(parents=True, exist_ok=True)

# ---------------- README ----------------
readme = """# Cuckoo v3.2 + GBDT Baseline (Reproducible Scaffold)

This repository provisions a **Linux host VM** (Ubuntu 22.04) that installs **Cuckoo Sandbox v3.2 (legacy)** and a **scikit-learn Gradient Boosted Decision Tree (GBDT)** post-processor that scores Cuckoo JSON reports.

> ⚠️ **Important**  
> - This package contains **no malware samples, Windows images, or model weights**.  
> - You must bring your own Windows 10 guest VM and configure it as a Cuckoo analysis machine (see notes below).  
> - This is **for research**; keep it isolated and comply with laws/policies.

## What you get
- Vagrantfile (Ubuntu 22.04 host)
- Ansible roles:
  - `cuckoo-host`: installs build deps, Python venv, and checks out Cuckoo v3.2 from Git (legacy)
  - `gbdt-postproc`: installs a tiny pipeline (`gbdt_train.py`, `gbdt_predict.py`) for scoring Cuckoo JSON
- Helper scripts to start Cuckoo and submit a benign sample.

## Quick start
```bash
# host machine (Linux/macOS with Vagrant + VirtualBox or libvirt)
cd cuckoo-gbdt-baseline
vagrant up          # provisions an Ubuntu 22.04 VM
vagrant ssh         # into the VM
sudo systemctl --now cuckoo@research
# In another shell on the VM you can submit samples:
/opt/cuckoo/bin/cuckoo submit /bin/true
