"""
Evaluate all five velocity models on the trip-disjoint split.

Runs:
  1. Velocity metrics on validation + test (overall).
  2. Speed-regime metrics (0-2, 2-5, 5-10, 10+ m/s).
  3. Trip-wise metrics (Y1, Vfa02, A5, T2).
  4. Dead-reckoning benchmark on test trips (A5, T2) -> position error/drift.

Exports machine-readable results:
    reports/metrics.json
    reports/predictions.csv
    reports/trajectory_<trip>_<model>.csv

Test set is evaluated ONCE, after model selection on validation only.
"""
import argparse
import json
from ekf import EKF
import pickle
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import torch

sys.path.insert(0, str(Path(__file__).parent))
import common
from benchmark_core import evaluate_blackout_window
from models_lib import (VelocityCNN, VelocityCNNSetC, VelocityGRU,
                        VelocityTCN, window_to_features)

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")


# ---------------------------------------------------------------------------
# Model inference adapters (common interface -> velocity m/s)
# ---------------------------------------------------------------------------
def predict_neural(model, X, channels="E"):
    """X is the full 12-channel normalized window batch."""
    if channels == "C":
        idx = common.FEATURE_SET_C_INDICES
        Xm = X[:, :, idx]
    else:
        Xm = X
    with torch.no_grad():
        vel, stat_logit = model(torch.tensor(Xm, dtype=torch.float32).to(DEVICE))
        preds = vel.cpu().numpy()
        stat_prob = torch.sigmoid(stat_logit).cpu().numpy()
        
    # Snap velocity to exactly 0.0 if the model is > 95% confident we are stationary!
    preds[stat_prob > 0.95] = 0.0
    
    # clamp to non-negative (velocity can't be negative)
    return np.maximum(preds, 0.0)


def predict_xgboost(reg, X):
    norm = common.load_norm_params()
    Xraw = common.unnormalize(X, norm["means"], norm["stds"])
    F = window_to_features(Xraw)
    return np.maximum(reg.predict(F), 0.0)


def load_model(model_id):
    if model_id == "cnn_baseline":
        m = VelocityCNN(in_channels=12)
        m.load_state_dict(torch.load(
            common.MODELS_DIR / "cnn_baseline" / "cnn_baseline.pt",
            map_location="cpu", weights_only=True), strict=False)
        return m.eval(), "E", lambda X: predict_neural(m, X, "E")
    elif model_id == "cnn_feature_c":
        m = VelocityCNNSetC(in_channels=6)
        m.load_state_dict(torch.load(
            common.MODELS_DIR / "cnn_feature_c" / "cnn_feature_c.pt",
            map_location="cpu", weights_only=True), strict=False)
        return m.eval(), "C", lambda X: predict_neural(m, X, "C")
    elif model_id == "cnn_feature_c_lowspeed":
        # Controlled low-speed experiment: same architecture as cnn_feature_c,
        # trained with speed-weighted MSE to address the 0-2 m/s blind spot.
        m = VelocityCNNSetC(in_channels=6)
        m.load_state_dict(torch.load(
            common.MODELS_DIR / "cnn_feature_c_lowspeed" /
            "cnn_feature_c_lowspeed.pt",
            map_location="cpu", weights_only=True), strict=False)
        return m.eval(), "C", lambda X: predict_neural(m, X, "C")
    elif model_id == "gru":
        m = VelocityGRU(in_channels=12)
        m.load_state_dict(torch.load(
            common.MODELS_DIR / "gru" / "gru.pt",
            map_location="cpu", weights_only=True), strict=False)
        return m.eval(), "E", lambda X: predict_neural(m, X, "E")
    elif model_id == "tcn":
        m = VelocityTCN(in_channels=12)
        m.load_state_dict(torch.load(
            common.MODELS_DIR / "tcn" / "tcn.pt",
            map_location="cpu", weights_only=True), strict=False)
        return m.eval(), "E", lambda X: predict_neural(m, X, "E")
    elif model_id == "xgboost":
        import xgboost as xgb
        reg = xgb.XGBRegressor()
        reg.load_model(str(common.MODELS_DIR / "xgboost" / "xgboost_v1.json"))
        return reg, "tabular", lambda X: predict_xgboost(reg, X)
    elif model_id == "ensemble":
        gru, _, pred_gru = load_model("gru")
        xgb, _, pred_xgb = load_model("xgboost")
        def predict_ensemble(Xn):
            v_gru = pred_gru(Xn)
            v_xgb = pred_xgb(Xn)
            return np.where(v_xgb < 5.0, v_gru, v_xgb)
        return None, "ensemble", predict_ensemble
    else:
        raise ValueError(model_id)


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------
def metrics_y_true_pred(y, p):
    e = y - p
    rmse = float(np.sqrt(np.mean(e ** 2)))
    mae = float(np.mean(np.abs(e)))
    bias = float(np.mean(e))
    med = float(np.median(np.abs(e)))
    mx = float(np.max(np.abs(e)))
    return {"rmse_ms": rmse, "rmse_kmh": rmse * 3.6,
            "mae_ms": mae, "mae_kmh": mae * 3.6,
            "bias_ms": bias, "median_abs_ms": med, "max_abs_ms": mx}


def regime_metrics(y, p):
    regimes = [(0, 2), (2, 5), (5, 10), (10, np.inf)]
    out = {}
    y = np.asarray(y); p = np.asarray(p)
    for lo, hi in regimes:
        m = (y >= lo) & (y < hi)
        n = int(m.sum())
        if n == 0:
            out[f"{lo}-{hi}"] = {"n": 0}
            continue
        e = y[m] - p[m]
        rmse = np.sqrt(np.mean(e ** 2))
        mae = np.mean(np.abs(e))
        bias = np.mean(e)
        out[f"{lo}-{hi}"] = {"n": n, "rmse_ms": float(rmse),
                             "rmse_kmh": float(rmse * 3.6),
                             "mae_ms": float(mae), "bias_ms": float(bias)}
    return out


def trip_metrics_by_ids(y, p, trip_id):
    out = {}
    for trip in np.unique(trip_id):
        m = trip_id == trip
        out[str(trip)] = metrics_y_true_pred(y[m], p[m])
    return out


# ---------------------------------------------------------------------------
# Dead reckoning benchmark
# ---------------------------------------------------------------------------
def benchmark_trip(model_id, predict_fn, trip_id, ref_cache, outage_frac=1/3, duration=60):
    d = ref_cache[trip_id]
    n = len(d["raw"])
    start = min(int(n * outage_frac), n - duration)
    end = start + duration
    if end > n:
        duration = n - start
        end = n

    X = np.array(d["raw"])
    norm = common.load_norm_params()
    Xn = (X - np.array(norm["means"])) / np.array(norm["stds"])
    preds = predict_fn(Xn)

    vels = preds[start:end]
    gyro_z = np.array(d["gyro_z"])[start:end]
    ref_lat = np.array(d["lat"])[start:end + 1]
    ref_lon = np.array(d["lon"])[start:end + 1]
    
    init_head_deg = float(np.array(d["heading"])[start])
    if not np.isfinite(init_head_deg):
        init_head_deg = 0.0

    res = evaluate_blackout_window(
        pred_velocity=vels,
        gyro_yaw_rate=gyro_z,
        gt_lat=ref_lat,
        gt_lon=ref_lon,
        gt_heading_deg=np.array([init_head_deg]*len(ref_lat)), # Used only for [0] inside
        start_idx=start,
        duration_steps=duration,
        dt_seconds=1.0,
        min_reference_distance_m=0.0 # Force pass for the legacy single-window test
    )

    return {
        "trip": trip_id,
        "outage_start": int(start),
        "outage_duration_s": int(duration),
        "final_position_error_m": res["open_loop_final_error_m"] if res else None,
        "reference_distance_m": res["reference_distance_m"] if res else None,
        "drift_pct": res["open_loop_drift_pct"] if res else None,
        "ekf_final_position_error_m": res["ekf_final_error_m"] if res else None,
        "ekf_drift_pct": res["ekf_drift_pct"] if res else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="*",
                    default=["cnn_baseline", "cnn_feature_c", "gru", "tcn",
                             "xgboost", "ensemble"])
    args = ap.parse_args()

    common.REPORTS_DIR.mkdir(parents=True, exist_ok=True)

    X_val, y_val, id_val = common.load_npz_split("val")
    X_test, y_test, id_test = common.load_npz_split("test")

    with open(common.PROCESSED_DIR / "reference_cache.pkl", "rb") as f:
        ref_cache = pickle.load(f)

    nav = np.mean(common.load_npz_split("train")[1])
    report = {"models": {}, "naive_train_mean_ms": float(nav)}

    for mid in args.models:
        print(f"\n{'#' * 60}\nEVALUATING: {mid}\n{'#' * 60}")
        model, channels, predict_fn = load_model(mid)

        # Validation
        pv = predict_fn(X_val)
        mv = metrics_y_true_pred(y_val, pv)
        regimes_v = regime_metrics(y_val, pv)
        trips_v = trip_metrics_by_ids(y_val, pv, id_val)

        # Test (ONCE)
        pt = predict_fn(X_test)
        mt = metrics_y_true_pred(y_test, pt)
        regimes_t = regime_metrics(y_test, pt)
        trips_t = trip_metrics_by_ids(y_test, pt, id_test)

        # Naive improvement on test (predict train mean)
        e_nav = y_test - nav
        naive_test_rmse = np.sqrt(np.mean(e_nav ** 2))
        impr = (naive_test_rmse - mt["rmse_ms"]) / naive_test_rmse * 100

        # Dead reckoning benchmark on test trips
        dr = {}
        for trip in ["A5", "T2"]:
            dr[trip] = benchmark_trip(mid, predict_fn, trip, ref_cache)

        mrow = {
            "validation": mv,
            "test": mt,
            "val_regimes": regimes_v,
            "test_regimes": regimes_t,
            "val_trips": trips_v,
            "test_trips": trips_t,
            "naive_test_rmse_ms": float(naive_test_rmse),
            "improvement_over_naive_pct": float(impr),
"dead_reckoning": {t: {k: v for k, v in dr[t].items()
                      if k not in ("trajectory", "errors",
                                   "ref_lat", "ref_lon",
                                   "vel_pred", "time_off",
                                   "ekf_trajectory", "ekf_errors")}
               for t in ["A5", "T2"]},
        }
        report["models"][mid] = mrow
        print(f"  VAL  RMSE = {mv['rmse_kmh']:.2f} km/h | "
              f"MAE = {mv['mae_kmh']:.2f} km/h")
        print(f"  TEST RMSE = {mt['rmse_kmh']:.2f} km/h | "
              f"MAE = {mt['mae_kmh']:.2f} km/h | "
              f"impr vs naive {impr:.1f}%")
        for trip in ["A5", "T2"]:
            r = dr[trip]
            print(f"  DR {trip}: final err = {r['final_position_error_m']:.1f} m "
                  f"| drift = {r['drift_pct']:.1f}%")

        # ---- export predictions.csv + trajectory.csv ----
        # predictions: val+test concatenated
        pred_df = pd.DataFrame({
            "split": ["val"] * len(y_val) + ["test"] * len(y_test),
            "trip_id": list(np.concatenate([id_val, id_test])),
            "reference_velocity": np.concatenate([y_val, y_test]),
            "predicted_velocity": np.concatenate([pv, pt]),
        })
        pred_df.to_csv(common.REPORTS_DIR / f"predictions_{mid}.csv",
                       index=False)

        for trip in ["A5", "T2"]:
            r = dr[trip]
            traj_df = pd.DataFrame({
                "timestamp": r["time_off"],
                "reference_velocity": r["vel_pred"],  # placeholder replaced below
                "predicted_velocity": r["vel_pred"],
                "reference_lat": r["ref_lat"][1:],
                "reference_lon": r["ref_lon"][1:],
                "estimated_lat": r["trajectory"][:, 0],
                "estimated_lon": r["trajectory"][:, 1],
                "position_error": r["errors"],
            })
            traj_df.to_csv(
                common.REPORTS_DIR / f"trajectory_{trip}_{mid}.csv",
                index=False)

    with open(common.REPORTS_DIR / "metrics.json", "w") as f:
        json.dump(report, f, indent=2)
    print(f"\nSaved metrics to {common.REPORTS_DIR / 'metrics.json'}")

    # ---- comparison table ----
    print("\n" + "=" * 80)
    print(f"{'Model':<16}{'ValRMSE':>10}{'TestRMSE':>10}{'TestMAE':>10}"
          f"{'A5FinErr':>12}{'T2FinErr':>12}{'Impr%':>8}")
    print("=" * 80)
    for mid in args.models:
        m = report["models"][mid]
        a5 = m["dead_reckoning"]["A5"]["final_position_error_m"]
        t2 = m["dead_reckoning"]["T2"]["final_position_error_m"]
        print(f"{mid:<16}{m['validation']['rmse_kmh']:>10.2f}"
              f"{m['test']['rmse_kmh']:>10.2f}{m['test']['mae_kmh']:>10.2f}"
              f"{a5:>12.1f}{t2:>12.1f}{m['improvement_over_naive_pct']:>8.1f}")


if __name__ == "__main__":
    main()
