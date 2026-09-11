#!/usr/bin/env python3
"""
Converts trained XGBoost model (xgboost_v1.json) into a compact representation
for high-speed on-device Dart evaluation (app/assets/models/xgboost_trees.json).
Also generates verification vectors to guarantee exact numerical parity in Dart.
"""

import json
import re
import os
import sys
from pathlib import Path
import numpy as np

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.append(str(PROJECT_ROOT / "src"))
from models_lib import window_to_features, FEATURE_NAMES

def main():
    xgb_json_path = PROJECT_ROOT / "models" / "xgboost" / "xgboost_v1.json"
    output_json_path = PROJECT_ROOT / "app" / "assets" / "models" / "xgboost_trees.json"
    output_json_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"[1/3] Reading {xgb_json_path}...")
    with open(xgb_json_path, "r") as f:
        data = json.load(f)

    learner = data["learner"]
    lmp = learner["learner_model_param"]
    base_score_str = lmp.get("base_score", "18.354538")
    match = re.search(r'[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?', str(base_score_str))
    base_score = float(match.group(0)) if match else 18.354538

    trees = learner["gradient_booster"]["model"]["trees"]
    print(f"[2/3] Extracting {len(trees)} trees (base_score={base_score})...")

    compact_trees = []
    for i, t in enumerate(trees):
        compact_trees.append({
            "l": t["left_children"],
            "r": t["right_children"],
            "s": t["split_indices"],
            "c": [round(float(v), 7) for v in t["split_conditions"]],
            "d": t["default_left"],
        })

    export_payload = {
        "base_score": base_score,
        "num_features": len(FEATURE_NAMES),
        "num_trees": len(compact_trees),
        "trees": compact_trees,
    }

    with open(output_json_path, "w") as f:
        json.dump(export_payload, f)
    print(f"Saved compact tree model to {output_json_path} ({os.path.getsize(output_json_path)} bytes)")

    # Generate a reference test vector from raw IMU window
    print("[3/3] Generating test vector from synthetic IMU window for Dart verification...")
    np.random.seed(42)
    sample_window = np.random.randn(1, 20, 12).astype(np.float32)
    # Give realistic gravity & accel
    sample_window[0, :, 3:6] = [0.0, 0.0, 9.81]
    sample_window[0, :, 0:3] = [0.1, -0.05, 0.02]
    sample_window[0, :, 6:9] = [0.01, -0.02, 0.03]

    feats = window_to_features(sample_window)[0]

    # Predict using tree walk
    def predict_tree_walk(features):
        total = base_score
        for tree in compact_trees:
            lefts = tree["l"]
            rights = tree["r"]
            splits = tree["s"]
            conds = tree["c"]
            defaults = tree["d"]
            node = 0
            while lefts[node] != -1:
                f_idx = splits[node]
                thresh = conds[node]
                val = features[f_idx]
                if np.isnan(val):
                    node = lefts[node] if defaults[node] else rights[node]
                elif val < thresh:
                    node = lefts[node]
                else:
                    node = rights[node]
            total += conds[node]
        return float(total)

    pred_val = predict_tree_walk(feats)
    print(f"Sample prediction: {pred_val:.6f} m/s")

    test_vector_path = PROJECT_ROOT / "app" / "assets" / "models" / "xgboost_test_vector.json"
    with open(test_vector_path, "w") as f:
        json.dump({
            "raw_window": sample_window[0].tolist(),
            "expected_features": [round(float(v), 6) for v in feats],
            "expected_prediction": round(pred_val, 6),
        }, f, indent=2)
    print(f"Saved test vector to {test_vector_path}")

if __name__ == "__main__":
    main()
