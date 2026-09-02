"""
Common data contract shared across all five velocity-estimation models.

Canonical internal unit: METRES PER SECOND (m/s).
km/h is used ONLY for display / reporting (multiply by 3.6).

All five models consume the SAME temporal window schema produced by the
corrected preprocessing pipeline (preprocess.py) and the same trip-disjoint
split defined in data/manifest.json:

    TRAIN:      S2, M, Vw4, Vtb5
    VALIDATION: Y1, Vfa02
    TEST:       A5, T2

Normalization statistics are computed ONLY from the training split and are
frozen into every exported model artifact. Validation/test/browser must all
use these exact statistics.
"""
from pathlib import Path
import numpy as np
import json
import hashlib
from datetime import datetime, timezone

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
DATASET_ROOT = Path(r"D:\Nandhu\dead reckoning\IO-VNBD-master")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
MODELS_DIR = PROJECT_ROOT / "models"
RESULTS_DIR = PROJECT_ROOT / "results"
REPORTS_DIR = PROJECT_ROOT / "reports"

# ---------------------------------------------------------------------------
# Channel schema (Feature Set E — the full 12-channel normalized ordering
# stored in the .npz files produced by the corrected preprocess.py).
# ---------------------------------------------------------------------------
CHANNEL_NAMES = [
    "Linear Accel X", "Linear Accel Y", "Linear Accel Z",
    "Gravity X",      "Gravity Y",      "Gravity Z",
    "Gyroscope Yaw",  "Gyroscope Pitch", "Gyroscope Roll",
    "Orientation Yaw","Orientation Pitch","Orientation Roll",
]

# Feature Set C: removes the problematic raw Orientation channels
# (indices 9,10,11) and uses Linear Accel + Gyro only.
FEATURE_SET_C_INDICES = [0, 1, 2, 6, 7, 8]
FEATURE_SET_C_NAMES = [CHANNEL_NAMES[i] for i in FEATURE_SET_C_INDICES]

TARGET_UNIT = "m/s"
SPLIT_TRIPS = {
    "train": ["S2", "M", "Vw4", "Vtb5", "A2", "Vw2", "Vw14b",
              "PVS_1", "PVS_2", "PVS_3", "PVS_4", "PVS_5",
              "PVS_6", "PVS_7", "A5", "T2"],
    "val":   ["Y1", "Vfa02"],
    "test":  ["PVS_8", "PVS_9"],
}

# Speed regimes in m/s used for regime-wise evaluation.
SPEED_REGIMES = [(0.0, 2.0), (2.0, 5.0), (5.0, 10.0), (10.0, np.inf)]

WINDOW_LENGTH = 20   # samples at 10 Hz = 2.0 s
WINDOW_STRIDE = 10   # 50% overlap -> 1.0 s per step


def load_norm_params():
    with open(PROCESSED_DIR / "norm_params.json", "r") as f:
        return json.load(f)


def load_npz_split(split):
    """Load a processed split. X is already normalized with training stats."""
    path = PROCESSED_DIR / f"{split}.npz"
    d = np.load(path)
    return d["X"].astype(np.float32), d["y"].astype(np.float32), d["trip_id"]


def assert_velocity_sane(y, label=""):
    """Contract assertions on the target velocity (m/s)."""
    y = np.asarray(y, dtype=float)
    assert np.all(np.isfinite(y)), f"{label}: non-finite velocity values"
    assert not np.isnan(y).any(), f"{label}: NaN in velocity"
    assert y.min() >= 0.0, f"{label}: negative velocity {y.min():.2f}"
    assert y.max() < 60.0, f"{label}: implausible velocity max {y.max():.2f} m/s"
    return True


def assert_input_sane(X, n_channels=12, label=""):
    X = np.asarray(X, dtype=float)
    assert np.all(np.isfinite(X)), f"{label}: non-finite input values"
    assert not np.isnan(X).any(), f"{label}: NaN in input"
    assert X.ndim == 3, f"{label}: expected 3D (batch, windows, channels), got {X.ndim}"
    assert X.shape[2] == n_channels, (
        f"{label}: channels = {X.shape[2]}, expected {n_channels}")
    return True


def unnormalize(X_norm, means, stds, indices=None):
    """Convert normalized window data back to raw IMU units."""
    means = np.asarray(means)
    stds = np.asarray(stds)
    if indices is not None:
        means = means[indices]
        stds = stds[indices]
    return X_norm * stds + means


def mps_to_kmh(v):
    return v * 3.6


def kmh_to_mps(v):
    return v / 3.6


def check_unit(value_mps, max_kmh=216.0):
    """Guard against accidentally mixing m/s and km/h."""
    v = float(value_mps)
    assert abs(v) < max_kmh / 3.6, (
        f"Value {v:.2f} looks like km/h mixed into m/s stream "
        f"(exceeds {max_kmh:.0f} km/h in m/s units). Value must be m/s.")
    return v

def get_utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()

def hash_file(path: str | Path) -> str:
    if not path or str(path) == "":
        return "N/A"
    path = Path(path)
    if not path.is_file():
        return "FILE_NOT_FOUND"
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()

if __name__ == "__main__":
    print("Common data contract module.")
    print(f"Target unit: {TARGET_UNIT}")
    print(f"Feature Set C channels: {FEATURE_SET_C_NAMES}")
    for s, trips in SPLIT_TRIPS.items():
        X, y, ids = load_npz_split(s)
        assert_velocity_sane(y, label=s)
        assert_input_sane(X, label=s)
        print(f"{s}: X={X.shape}, y={y.shape}, trips={list(np.unique(ids))}, "
              f"vel m/s [{y.min():.2f}, {y.max():.2f}]")
    print("All data contract assertions PASSED (m/s canonical internal unit).")
