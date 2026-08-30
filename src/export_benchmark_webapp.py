"""
Export the fixed dead-reckoning benchmark (MODE 2) to the webapp.

Generates webapp/public/model/benchmark.json containing, for test trips
A5 and T2:

    - reference arrays (lat/lon/vel/heading/gyro_z) for the FULL trip
    - per-model full-trip predicted velocity (recomputed from the same
      trained checkpoints + normalization used by evaluate_all.py)
    - the fixed outage window (start = n//3, duration = 60 s)
    - offline-computed per-model DR trajectories + per-step errors for the
      outage (identical to reports/metrics.json values)
    - raw IMU windows for the outage segment (for live TF.js inference of
      cnn_feature_c and IMU-derived ZUPT demonstration)
    - per-window stationary flags (IMU-derived, model-independent)
    - a metrics summary copied from reports/metrics.json

Parity assertions guarantee the exported numbers match the offline benchmark
exactly (same code path as evaluate_all.py).
"""
import json
import pickle
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import common
import evaluate_all as E

OUT_DIR = common.PROJECT_ROOT / "webapp" / "public" / "model"
TRIPS = ["A5", "T2"]
MODELS = ["cnn_baseline", "cnn_feature_c_lowspeed",
          "gru", "tcn", "xgboost"]
OUTAGE_FRAC = 1.0 / 3.0
DURATION = 60


def r6(x):
    return [round(float(v), 6) for v in x]


def r4(x):
    return [round(float(v), 4) for v in x]


def r3(x):
    return [round(float(v), 3) for v in x]


def stationary_flags(raw):
    """IMU-derived stationary detection (model-independent).

    Matches the webapp ZUPT thresholds: low accel-norm std AND low
    gyro-norm std within the estimation window.
    """
    ax, ay, az = raw[:, :, 0], raw[:, :, 1], raw[:, :, 2]
    gx, gy, gz = raw[:, :, 6], raw[:, :, 7], raw[:, :, 8]
    am = np.sqrt(ax ** 2 + ay ** 2 + az ** 2)
    gm = np.sqrt(gx ** 2 + gy ** 2 + gz ** 2)
    return ((am.std(axis=1) < 0.50) & (gm.std(axis=1) < 0.07)).astype(int)


def export_trip(trip_id, ref_cache, models, metrics):
    d = ref_cache[trip_id]
    n = len(d["raw"])
    start = min(int(n * OUTAGE_FRAC), n - DURATION)
    if start < 0:
        start = 0
    end = min(start + DURATION, n)
    duration = end - start

    raw = np.asarray(d["raw"], dtype=float)
    norm = common.load_norm_params()
    Xn = (raw - np.array(norm["means"])) / np.array(norm["stds"])

    trip = {
        "n": int(n),
        "outageStart": int(start),
        "outageDuration": int(duration),
        "ref": {
            "lat": r6(d["lat"]),
            "lon": r6(d["lon"]),
            "vel": r4(d["vel"]),
            "heading": r4(d["heading"]),
            "gyroZ": [round(float(v), 6) for v in d["gyro_z"]],
        },
        "stationary": stationary_flags(raw).tolist(),
        "models": {},
        # raw IMU windows only for the outage segment (live TF.js + ZUPT)
        "outageWindows": np.round(raw[start:end], 4).tolist(),
    }

    for mid, predict_fn in models.items():
        if mid not in metrics["models"]: continue
        preds = predict_fn(Xn)
        # Fixed benchmark replay (same code path as evaluate_all.py)
        res = E.benchmark_trip(mid, predict_fn, trip_id, ref_cache,
                               outage_frac=OUTAGE_FRAC, duration=DURATION)
        # Parity check against offline metrics
        mm = metrics["models"][mid]["dead_reckoning"][trip_id]
        assert abs(res["final_position_error_m"]
                   - mm["final_position_error_m"]) < 1e-6, \
            f"parity failure {mid}/{trip_id}"
        # Map cnn_feature_c_lowspeed back to cnn_feature_c for the webapp UI
        out_mid = mid if mid != "cnn_feature_c_lowspeed" else "cnn_feature_c"
        trip["models"][out_mid] = {
            "vel": r4(preds),
            "outage": {
                "trajLat": r6(res["trajectory"][:, 0]),
                "trajLon": r6(res["trajectory"][:, 1]),
                "err": r3(res["errors"]),
                "vel": r4(res["vel_pred"]),
                "ekf_trajLat": r6(res["ekf_trajectory"][:, 0]) if "ekf_trajectory" in res else [],
                "ekf_trajLon": r6(res["ekf_trajectory"][:, 1]) if "ekf_trajectory" in res else [],
                "ekf_err": r3(res["ekf_errors"]) if "ekf_errors" in res else [],
            },
        }
    return trip


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with open(common.PROCESSED_DIR / "reference_cache.pkl", "rb") as f:
        ref_cache = pickle.load(f)
    with open(common.REPORTS_DIR / "metrics.json") as f:
        metrics = json.load(f)

    models = {}
    for mid in MODELS:
        _, _, predict_fn = E.load_model(mid)
        models[mid] = predict_fn

    out = {
        "version": "benchmark_v1",
        "canonicalUnits": "m/s",
        "normalizationVersion": "corrected_v1",
        "naiveTrainMeanMs": float(metrics["naive_train_mean_ms"]),
        "metricsSummary": {
            (mid if mid != "cnn_feature_c_lowspeed" else "cnn_feature_c"): {
                "valRmseKmh": metrics["models"][mid]["validation"]["rmse_kmh"],
                "testRmseKmh": metrics["models"][mid]["test"]["rmse_kmh"],
                "testMaeKmh": metrics["models"][mid]["test"]["mae_kmh"],
                "valRegimes": metrics["models"][mid]["val_regimes"],
                "dr": metrics["models"][mid]["dead_reckoning"],
            } for mid in MODELS if mid in metrics["models"]
        },
        "trips": {},
    }

    for trip_id in TRIPS:
        print(f"Exporting {trip_id} ...")
        out["trips"][trip_id] = export_trip(trip_id, ref_cache, models,
                                            metrics)

    out_path = OUT_DIR / "benchmark.json"
    with open(out_path, "w") as f:
        json.dump(out, f)
    size_mb = out_path.stat().st_size / 1e6
    print(f"Wrote {out_path} ({size_mb:.2f} MB)")


if __name__ == "__main__":
    main()
