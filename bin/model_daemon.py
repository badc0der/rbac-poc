#!/usr/bin/env python3
"""
model_daemon.py
Model-based detector:
  - Collects the shared 36-feature view via feature_collector.Collector
  - Applies the saved preprocessor + model (XGBoost-compatible; any sklearn estimator)
  - Emits CSV & log, and flips SELinux boolean "ml_block" when P(enc) >= block-threshold

Usage:
  model_daemon.py \
    --model /opt/rbac-poc/artefacts/best_model.joblib \
    --preproc /opt/rbac-poc/artefacts/preprocessor.joblib \
    --feature-order /opt/rbac-poc/artefacts/feature_order.json \
    --keys /opt/rbac-poc/artefacts/ftrace_keys.json \
    --csv /opt/rbac-poc/logs/decisions_model.csv \
    --log /opt/rbac-poc/logs/model_daemon.log \
    --block-threshold 0.50 --interval 0.20
"""
import argparse, json, time, csv, logging, subprocess, signal, sys
from pathlib import Path

import joblib
import pandas as pd

# shared collector
sys.path.insert(0, "/opt/rbac-poc/bin")
from feature_collector import Collector  # noqa: E402

DEFAULT_BOOL = "ml_block"

def set_selinux_boolean(name: str, value: bool) -> None:
    cmd = ["/usr/sbin/setsebool", f"{name}={'on' if value else 'off'}"]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        logging.warning("setsebool not found; SELinux boolean flip skipped.")
    except subprocess.CalledProcessError as e:
        logging.error("setsebool failed: %s", e.stderr.decode(errors="ignore").strip())

def load_feature_order(path: Path):
    # expects a JSON list of feature names in model/preprocessor training order
    return list(json.loads(path.read_text()))

def predict_proba_one(model, X_df: pd.DataFrame) -> float:
    """
    Returns probability of encryption (class 1).
    Supports sklearn API and xgboost XGBClassifier saved via joblib.
    """
    # Many estimators expose predict_proba; fall back to decision_function if needed.
    if hasattr(model, "predict_proba"):
        p = model.predict_proba(X_df)
        # assume binary [p0, p1]
        return float(p[0, 1])
    if hasattr(model, "decision_function"):
        import numpy as np
        d = float(model.decision_function(X_df)[0])
        # logistic squash to [0,1]
        return float(1.0 / (1.0 + np.exp(-d)))
    # worst-case: predict {0,1}
    y = int(model.predict(X_df)[0])
    return 1.0 if y == 1 else 0.0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--preproc", required=True)
    ap.add_argument("--feature-order", required=True)
    ap.add_argument("--keys", required=True)
    ap.add_argument("--csv", default="/opt/rbac-poc/logs/decisions_model.csv")
    ap.add_argument("--log", default="/opt/rbac-poc/logs/model_daemon.log")
    ap.add_argument("--block-threshold", type=float, default=0.50)
    ap.add_argument("--interval", type=float, default=0.20, help="sampling interval (seconds)")
    ap.add_argument("--boolean", default=DEFAULT_BOOL)
    args = ap.parse_args()

    Path(args.log).parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(filename=args.log, level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    logging.info("model_daemon starting; model=%s preproc=%s", args.model, args.preproc)

    # Load artefacts
    feature_order = load_feature_order(Path(args.feature_order))
    preproc = joblib.load(args.preproc)
    model = joblib.load(args.model)
    coll = Collector(args.keys)

    # CSV writer
    csv_path = Path(args.csv)
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    csv_file = csv_path.open("a", newline="")
    csv_w = csv.DictWriter(csv_file, fieldnames=[
        "ts","penc","block","threshold","features_json"
    ])
    if csv_path.stat().st_size == 0:
        csv_w.writeheader()

    running = True
    def _stop(_s, _f):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    last_block = None

    while running:
        t0 = time.time()
        feat = coll.collect()  # dict of all 36 features (and counts for keys)
        # Build a single-row DataFrame aligned to feature_order
        row = {k: float(feat.get(k, 0.0)) for k in feature_order}
        X = pd.DataFrame([row], columns=feature_order)

        try:
            Xp = preproc.transform(X)
        except Exception:
            # If preproc is a Pipeline with ColumnTransformer, it should accept DF;
            # if not, fallback to passthrough
            Xp = X.values

        penc = predict_proba_one(model, pd.DataFrame(Xp))

        block = bool(penc >= args.block_threshold)
        if last_block is None or block != last_block:
            set_selinux_boolean(args.boolean, block)
            logging.info("ml_block=%s penc=%.4f thr=%.2f", block, penc, args.block_threshold)
            last_block = block

        # CSV log
        try:
            csv_w.writerow({
                "ts": f"{t0:.6f}",
                "penc": f"{penc:.6f}",
                "block": int(block),
                "threshold": f"{args.block_threshold:.2f}",
                "features_json": json.dumps(row, separators=(",",":"))
            })
            csv_file.flush()
        except Exception as e:
            logging.warning("CSV write failed: %s", e)

        dt = time.time() - t0
        time.sleep(max(0.0, args.interval - dt))

    csv_file.close()
    logging.info("model_daemon exiting cleanly.")

if __name__ == "__main__":
    main()
