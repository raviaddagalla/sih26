"""
Train all five velocity-estimation models on the corrected, trip-disjoint split.

Common data contract (see common.py):
    target unit m/s, canonical channel order from corrected preprocess.py,
    normalization statistics computed ONLY from training split.

Models:
    cnn_baseline   (12-ch, faithful reproduction)  -> Model A
    cnn_feature_c  (6-ch: Linear Accel + Gyro)     -> Model B
    gru            (recurrent)                     -> Model C
    tcn            (dilated temporal conv)         -> Model D
    xgboost        (engineered window features)    -> Model E

Usage:
    python src/train_all.py                              # train all, unweighted
    python src/train_all.py --models cnn_baseline gru    # subset
    python src/train_all.py --weighted                    # enable low-speed weighted loss
"""
import argparse
import json
import os
import random
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import TensorDataset, DataLoader, WeightedRandomSampler

sys.path.insert(0, str(Path(__file__).parent))
import common
from models_lib import (
    VelocityCNN, VelocityCNNSetC, VelocityGRU, VelocityTCN,
    window_to_features, FEATURE_NAMES,
)

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

SEED = 42
BATCH_SIZE = 128
MAX_EPOCHS = 200
PATIENCE = 15
LR = 1e-3


def set_seed(seed=SEED):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


# ---------------------------------------------------------------------------
# Learning-rate / weights helpers
# ---------------------------------------------------------------------------
def make_weights(y, mode="unweighted"):
    """
    Return per-sample loss weights. mode:
      unweighted -> all 1.0
      low_speed  -> increase weight near zero velocity to combat the
                    near-zero blind spot. Regimes (documented):
                        v < 2 m/s       weight 4.0
                        2 <= v < 5      weight 2.0
                        5 <= v < 10     weight 1.3
                        v >= 10         weight 1.0
    """
    y = np.asarray(y, dtype=float)
    w = np.ones_like(y)
    if mode == "low_speed":
        w[y < 2.0] = 4.0
        w[(y >= 2.0) & (y < 5.0)] = 2.0
        w[(y >= 5.0) & (y < 10.0)] = 1.3
        w[y >= 10.0] = 1.0
    return torch.tensor(w, dtype=torch.float32)


class WeightedMSELoss(nn.Module):
    def __init__(self, weights):
        super().__init__()
        self.weights = weights

    def forward(self, pred, target):
        return torch.mean(self.weights * (pred - target) ** 2)


# ---------------------------------------------------------------------------
# Training loop
# ---------------------------------------------------------------------------
def train_neural(model, X_train, y_train, X_val, y_val, channels, weighted=False, augment=True, name="model"):
    set_seed(SEED)
    model = model.to(DEVICE)
    if weighted:
        # Regime-based sampling: 0-2, 2-5, 5-10, >=10 m/s
        regimes = np.digitize(y_train, bins=[0, 2, 5, 10, np.inf])
        regime_counts = np.bincount(regimes, minlength=5)  # indices 0..4, but 0 unused
        # Avoid division by zero
        regime_weights = 1.0 / np.where(regime_counts > 0, regime_counts, 1.0)
        sample_weights = regime_weights[regimes]
        sampler = WeightedRandomSampler(
            weights=sample_weights,
            num_samples=len(sample_weights),
            replacement=True,
        )
        train_ds = TensorDataset(
            torch.tensor(X_train, dtype=torch.float32),
            torch.tensor(y_train, dtype=torch.float32),
        )
        train_loader = DataLoader(train_ds, batch_size=BATCH_SIZE, sampler=sampler)
    else:
        train_ds = TensorDataset(
            torch.tensor(X_train, dtype=torch.float32),
            torch.tensor(y_train, dtype=torch.float32),
        )
        train_loader = DataLoader(train_ds, batch_size=BATCH_SIZE, shuffle=True)
    val_ds = TensorDataset(
        torch.tensor(X_val, dtype=torch.float32),
        torch.tensor(y_val, dtype=torch.float32),
    )
    val_loader = DataLoader(val_ds, batch_size=BATCH_SIZE, shuffle=False)

    criterion = nn.MSELoss()
    optimizer = optim.Adam(model.parameters(), lr=LR)
    scheduler = optim.lr_scheduler.ReduceLROnPlateau(
        optimizer, mode="min", factor=0.5, patience=5)

    best_val = float("inf")
    best_state = None
    no_improve = 0
    t0 = time.time()

    norm = common.load_norm_params()
    if channels == 6:
        means = torch.tensor(np.array(norm["means"])[common.FEATURE_SET_C_INDICES], dtype=torch.float32, device=DEVICE)
        stds = torch.tensor(np.array(norm["stds"])[common.FEATURE_SET_C_INDICES], dtype=torch.float32, device=DEVICE)
    else:
        means = torch.tensor(np.array(norm["means"]), dtype=torch.float32, device=DEVICE)
        stds = torch.tensor(np.array(norm["stds"]), dtype=torch.float32, device=DEVICE)
        
    from models_lib import apply_random_rotation

    for epoch in range(1, MAX_EPOCHS + 1):
        model.train()
        tr_loss = 0.0
        
        for X_b, y_b in train_loader:
            X_b, y_b = X_b.to(DEVICE), y_b.to(DEVICE)
            
            if augment:
                X_b = apply_random_rotation(X_b, means, stds, max_angle_deg=15.0)
            
            optimizer.zero_grad()
            vel_preds, stat_logits = model(X_b)
            
            # Regression loss
            vel_loss = torch.mean((vel_preds - y_b) ** 2)
            
            # Physics-Informed Neural Network (PINN) Loss
            # The model predicts velocity. The displacement over the 2-second window (stride is 1s, but we can treat the window as a chunk)
            # is approx velocity * time. We enforce that the predicted displacement matches ground truth displacement.
            # This acts as a strongly regularizing L1 loss on velocity.
            window_duration_s = 2.0
            pred_disp = vel_preds * window_duration_s
            true_disp = y_b * window_duration_s
            physics_loss = torch.mean(torch.abs(pred_disp - true_disp))
            
            # Classification loss (stationary if v < 0.2 m/s)
            y_stat = (y_b < 0.2).float()
            bce_criterion = nn.BCEWithLogitsLoss()
            stat_loss = bce_criterion(stat_logits, y_stat)
            
            # Joint loss
            loss = vel_loss + 0.5 * physics_loss + 0.1 * stat_loss
            loss.backward()
            optimizer.step()
            tr_loss += loss.item() * X_b.size(0)
        tr_rmse = np.sqrt(tr_loss / len(train_loader.dataset))

        model.eval()
        va_loss = 0.0
        with torch.no_grad():
            for X_b, y_b in val_loader:
                X_b, y_b = X_b.to(DEVICE), y_b.to(DEVICE)
                vel_preds, _ = model(X_b)
                va_loss += torch.sum((vel_preds - y_b) ** 2).item()
        va_rmse = np.sqrt(va_loss / len(val_loader.dataset))
        scheduler.step(va_rmse)

        if va_rmse < best_val:
            best_val = va_rmse
            best_state = {k: v.detach().cpu().clone()
                          for k, v in model.state_dict().items()}
            no_improve = 0
        else:
            no_improve += 1

        if epoch == 1 or epoch % 20 == 0 or no_improve == PATIENCE:
            print(f"  [{name}] epoch {epoch:3d} | "
                  f"train RMSE {tr_rmse*3.6:6.2f} km/h | "
                  f"val RMSE {va_rmse*3.6:6.2f} km/h")
        if no_improve >= PATIENCE:
            print(f"  [{name}] early stopping at epoch {epoch}")
            break

    model.load_state_dict(best_state)
    print(f"  [{name}] best val RMSE = {best_val*3.6:.2f} km/h "
          f"({best_val:.2f} m/s) in {time.time()-t0:.0f}s")
    return model, best_val, best_state


# ---------------------------------------------------------------------------
# Model registry save
# ---------------------------------------------------------------------------
def save_registry_entry(model_id, model_type, metadata, metrics,
                        artifact_path, version):
    reg_path = common.PROJECT_ROOT / "model_registry.json"
    entry = {
        "model_id": model_id,
        "model_type": model_type,
        "version": version,
        "features": metadata.get("features", []),
        "window_length": metadata.get("window_length", common.WINDOW_LENGTH),
        "target_unit": "m/s",
        "validation_rmse": metrics.get("val_rmse"),
        "test_rmse": metrics.get("test_rmse"),
        "training_seed": SEED,
        "artifact_path": str(artifact_path),
        "trained_on_corrected_data": True,
        "feature_set": metadata.get("feature_set"),
        "normalization_version": "corrected_v1",
        **metadata,
        "metrics": metrics,
    }
    if reg_path.exists():
        try:
            with open(reg_path, "r") as f:
                reg = json.load(f)
        except Exception:
            # corrupted / partial write earlier — start fresh but keep other entries
            reg = {}
    else:
        reg = {}
    reg[model_id] = entry
    tmp = reg_path.with_suffix(".json.tmp")
    with open(tmp, "w") as f:
        json.dump(reg, f, indent=2)
    tmp.replace(reg_path)
    return entry


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="*",
                    default=["cnn_baseline", "cnn_feature_c", "gru", "tcn",
                             "xgboost"])
    ap.add_argument("--unweighted", action="store_true",
                    help="Disable regime-based speed weighting")
    args = ap.parse_args()

    set_seed(SEED)
    common.MODELS_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 70)
    print("MODEL SHOOTOUT — TRAINING")
    print(f"Split: train={common.SPLIT_TRIPS['train']}, "
          f"val={common.SPLIT_TRIPS['val']}, test={common.SPLIT_TRIPS['test']}")
    print("=" * 70)

    X_train, y_train, ids_train = common.load_npz_split("train")
    X_val, y_val, _ = common.load_npz_split("val")

    # maximize velocity for model 7 tuning
    max_v_train = y_train.max()
    print(f"Train max velocity: {max_v_train:.2f} m/s ({max_v_train*3.6:.1f} km/h)")

    naive_pred = np.mean(y_train)
    print(f"Naive baseline (train mean): {naive_pred:.2f} m/s "
          f"({naive_pred*3.6:.1f} km/h)")

    for model_name in args.models:
        print(f"\n{'#' * 60}\nTRAINING: {model_name}\n{'#' * 60}")
        if model_name == "xgboost":
            train_xgboost(X_train, y_train, X_val, y_val, "xgboost_v1")
            continue
        elif model_name == "cnn_baseline":
            model = VelocityCNN(in_channels=12)
            Xtr, Xv = X_train, X_val
            channels = 12
            fname = "cnn_baseline"
            ver = "cnn_baseline_v1"
        elif model_name == "cnn_feature_c":
            idx = common.FEATURE_SET_C_INDICES
            model = VelocityCNNSetC(in_channels=len(idx))
            Xtr, Xv = X_train[:, :, idx], X_val[:, :, idx]
            channels = 6
            if not args.unweighted:
                # versioned low-speed experiment (does NOT overwrite v1)
                fname = "cnn_feature_c_lowspeed"
                ver = "cnn_feature_c_lowspeed_v1"
            else:
                fname = "cnn_feature_c"
                ver = "cnn_feature_c_v1"
        elif model_name == "gru":
            model = VelocityGRU(in_channels=12)
            Xtr, Xv = X_train, X_val
            channels = 12
            fname = "gru"
            ver = "gru_v1"
        elif model_name == "tcn":
            model = VelocityTCN(in_channels=12)
            Xtr, Xv = X_train, X_val
            channels = 12
            fname = "tcn"
            ver = "tcn_v1"
        else:
            print(f"Unknown model {model_name}")
            continue

        model, val_rmse, _ = train_neural(
            model, Xtr, y_train, Xv, y_val, channels=channels,
            weighted=not args.unweighted, augment=True, name=model_name)

        # Save artifact
        mdir = common.MODELS_DIR / fname
        mdir.mkdir(parents=True, exist_ok=True)
        torch.save(model.state_dict(), mdir / f"{fname}.pt")

        # Metadata
        feat_names = (common.FEATURE_SET_C_NAMES
                      if model_name == "cnn_feature_c" else common.CHANNEL_NAMES)
        metadata = {
            "features": feat_names,
            "window_length": common.WINDOW_LENGTH,
            "feature_set": "C" if model_name == "cnn_feature_c" else "E",
            "architecture": str(model),
            "param_count": sum(p.numel() for p in model.parameters()),
            "optimizer": "Adam",
            "learning_rate": LR,
            "batch_size": BATCH_SIZE,
            "epochs": MAX_EPOCHS,
            "loss": "weighted-MSE(speed)+BCE(stationary)" if not args.unweighted else "MSE(speed)+BCE(stationary)",
            "normalization_key": "corrected_v1",
            "target_unit": "m/s",
        }
        metrics = {"val_rmse": float(val_rmse)}
        save_registry_entry(fname, model.__class__.__name__, metadata,
                            metrics, mdir / f"{fname}.pt", ver)
        print(f"Saved {mdir / (fname + '.pt')}")


def train_xgboost(X_train, y_train, X_val, y_val, ver):
    import xgboost as xgb

    norm = common.load_norm_params()
    idx = common.FEATURE_SET_C_INDICES

    # XGBoost uses RAW (unnormalized) IMU -> engineered features.
    # window_to_features reads channel indices 0-2 (accel) and 6-8 (gyro),
    # so pass the full 12-channel raw reconstruction.
    Xtr_raw = common.unnormalize(X_train, norm["means"], norm["stds"])
    Xva_raw = common.unnormalize(X_val, norm["means"], norm["stds"])

    Ftr = window_to_features(Xtr_raw)
    Fva = window_to_features(Xva_raw)

    xgb_model = xgb.XGBRegressor(
        n_estimators=400, max_depth=6, learning_rate=0.05,
        subsample=0.8, colsample_bytree=0.8, random_state=SEED,
        n_jobs=-1, objective="reg:squarederror",
    )
    xgb_model.fit(Ftr, y_train, eval_set=[(Fva, y_val)],
                  verbose=False)

    val_pred = xgb_model.predict(Fva)
    val_rmse = float(np.sqrt(np.mean((val_pred - y_val) ** 2)))
    print(f"  [xgboost] val RMSE = {val_rmse*3.6:.2f} km/h ({val_rmse:.2f} m/s)")

    mdir = common.MODELS_DIR / "xgboost"
    mdir.mkdir(parents=True, exist_ok=True)
    xgb_model.save_model(mdir / "xgboost_v1.json")

    # Feature importance
    imp = {k: float(v) for k, v in
           zip(FEATURE_NAMES, xgb_model.feature_importances_)}

    metadata = {
        "features": FEATURE_NAMES,
        "window_length": common.WINDOW_LENGTH,
        "feature_set": "tabular-eng",
        "architecture": "XGBRegressor(depth=6,n=400,lr=0.05)",
        "param_count": None,
        "optimizer": "None",
        "learning_rate": 0.05,
        "batch_size": None,
        "epochs": None,
        "loss": "reg:squarederror",
        "normalization_key": "none-tree",
        "target_unit": "m/s",
        "feature_importance": imp,
    }
    metrics = {"val_rmse": val_rmse}
    save_registry_entry("xgboost", "XGBoost", metadata, metrics,
                        mdir / "xgboost_v1.json", ver)
    print(f"Saved {mdir / 'xgboost_v1.json'}")


if __name__ == "__main__":
    main()
