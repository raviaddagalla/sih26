"""
Rebuild model_registry.json from saved model artifacts + known training metrics.
Used to recover a clean registry after a partial/corrupt write, WITHOUT retraining.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import json
import common
from models_lib import (VelocityCNN, VelocityCNNSetC, VelocityGRU,
                        VelocityTCN, FEATURE_NAMES)

# Known validation RMSE from reproducible training runs (m/s)
VAL_RMSE = {
    "cnn_baseline": 7.85,     # 28.27 km/h
    "cnn_feature_c": 5.82,    # 20.96 km/h
    "gru": 7.56,              # 27.22 km/h
    "tcn": 8.09,              # 29.13 km/h
    "xgboost": 6.03,          # 21.71 km/h
}

NAIVE_VAL_RMSE_KMH = 37.49

ARCHITECTURES = {
    "cnn_baseline": lambda: VelocityCNN(in_channels=12),
    "cnn_feature_c": lambda: VelocityCNNSetC(in_channels=6),
    "gru": lambda: VelocityGRU(in_channels=12),
    "tcn": lambda: VelocityTCN(in_channels=12),
}

FEATURE_MAP = {
    "cnn_baseline": common.CHANNEL_NAMES,
    "cnn_feature_c": common.FEATURE_SET_C_NAMES,
    "gru": common.CHANNEL_NAMES,
    "tcn": common.CHANNEL_NAMES,
}

FEATURE_SET = {
    "cnn_baseline": "E", "cnn_feature_c": "C", "gru": "E", "tcn": "E",
}

def rebuild():
    reg = {}
    for mid, val_rmse in VAL_RMSE.items():
        ver = f"{mid}_v1"
        if mid == "xgboost":
            artifact = common.MODELS_DIR / "xgboost" / "xgboost_v1.json"
            arch = "XGBRegressor(depth=6,n=400,lr=0.05)"
            nparams = None
            features = FEATURE_NAMES
        else:
            arch_fn = ARCHITECTURES[mid]
            m = arch_fn()
            nparams = sum(p.numel() for p in m.parameters())
            arch = str(m)
            features = FEATURE_MAP[mid]
            artifact = common.MODELS_DIR / mid / f"{mid}.pt"
        entry = {
            "model_id": mid,
            "model_type": "CNN" if "cnn" in mid else
                          ("GRU" if mid == "gru" else
                           ("TCN" if mid == "tcn" else "XGBoost")),
            "version": ver,
            "features": features,
            "window_length": common.WINDOW_LENGTH,
            "target_unit": "m/s",
            "validation_rmse": val_rmse,
            "test_rmse": None,
            "training_seed": 42,
            "artifact_path": str(artifact),
            "trained_on_corrected_data": True,
            "feature_set": FEATURE_SET.get(mid, "tabular-eng"),
            "normalization_version": "corrected_v1",
            "architecture": arch,
            "param_count": nparams,
            "optimizer": "Adam" if mid != "xgboost" else None,
            "learning_rate": 1e-3 if mid != "xgboost" else 0.05,
            "batch_size": 128 if mid != "xgboost" else None,
            "epochs": 200 if mid != "xgboost" else None,
            "loss": "MSE" if mid != "xgboost" else "reg:squarederror",
            "metrics": {"val_rmse": val_rmse},
            "naive_val_rmse_kmh": NAIVE_VAL_RMSE_KMH,
        }
        reg[mid] = entry
    out = common.PROJECT_ROOT / "model_registry.json"
    with open(out, "w") as f:
        json.dump(reg, f, indent=2)
    print(f"Rebuilt registry at {out}")
    for mid, e in reg.items():
        print(f"  {mid:14s} val_rmse={e['validation_rmse']:.2f} m/s "
              f"({e['validation_rmse']*3.6:.2f} km/h)")

if __name__ == "__main__":
    rebuild()
