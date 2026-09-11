import math
import sys
from pathlib import Path
from typing import List, Optional

import numpy as np
import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field

# Add project root and src to path
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.append(str(PROJECT_ROOT / "src"))

import common
from models_lib import VelocityGRU, window_to_features

app = FastAPI(
    title="Intelligent Dead Reckoning (IDR) Edge Engine",
    description="High-performance, edge-deployable navigation software engine supporting up to 200Hz FOG-grade IMU sensor streaming and multi-model ensemble fusion.",
    version="2.0.0",
)

DEVICE = torch.device("cuda" if torch.cuda.is_available() else "cpu")

# ---------------------------------------------------------------------------
# Load Model Artifacts (Identical Regime-Based Ensemble as Mobile App)
# ---------------------------------------------------------------------------
gru_model: Optional[VelocityGRU] = None
xgb_regressor = None
norm_params = None

try:
    # 1. Load GRU PyTorch model
    gru_path = PROJECT_ROOT / "models" / "gru" / "gru.pt"
    if gru_path.exists():
        gru_model = VelocityGRU(in_channels=12).to(DEVICE)
        gru_model.load_state_dict(torch.load(gru_path, map_location=DEVICE, weights_only=True))
        gru_model.eval()
        print(f"[EDGE ENGINE] Loaded GRU model from {gru_path}")

    # 2. Load XGBoost model
    import xgboost as xgb
    xgb_path = PROJECT_ROOT / "models" / "xgboost" / "xgboost_v1.json"
    if xgb_path.exists():
        xgb_regressor = xgb.XGBRegressor()
        xgb_regressor.load_model(str(xgb_path))
        print(f"[EDGE ENGINE] Loaded XGBoost model from {xgb_path}")

    norm_params = common.load_norm_params()
except Exception as e:
    print(f"[EDGE ENGINE] Warning: Model initialization warning: {e}. Running in kinematic fallback mode.")


# ---------------------------------------------------------------------------
# 200Hz High-Rate EKF State & Propagator
# ---------------------------------------------------------------------------
class HighRateEkfState:
    def __init__(self):
        self.lat = 12.9716  # Default Bangalore origin
        self.lon = 77.5946
        self.alt = 920.0
        self.vn = 0.0  # Velocity North (m/s)
        self.ve = 0.0  # Velocity East (m/s)
        self.vd = 0.0  # Velocity Down (m/s)
        self.heading = 0.0  # Heading radians
        self.roll = 0.0
        self.pitch = 0.0
        self.pos_var = 4.0  # Position variance (m^2)
        self.vel_var = 0.25
        self.gnss_active = True
        self.last_timestamp = 0.0

    def predict(self, dt: float, ax: float, ay: float, az: float, gx: float, gy: float, gz: float):
        """Propagates vehicle state forward in time using raw IMU rates at up to 200Hz."""
        # 1. Attitude update from gyroscope
        self.heading += gz * dt
        self.pitch += gy * dt
        self.roll += gx * dt

        # 2. Forward acceleration in horizontal vehicle frame
        # Forward speed = sqrt(vn^2 + ve^2)
        cos_h = math.cos(self.heading)
        sin_h = math.sin(self.heading)

        # Vehicle body forward accel (ax) mapped to North & East
        an = ax * cos_h - ay * sin_h
        ae = ax * sin_h + ay * cos_h

        self.vn += an * dt
        self.ve += ae * dt

        # Non-Holonomic Constraint damping on lateral velocity
        v_forward = self.vn * cos_h + self.ve * sin_h
        v_forward = max(0.0, v_forward)
        self.vn = v_forward * cos_h
        self.ve = v_forward * sin_h

        # 3. Position integration (WGS84 approx: 111,139 m/deg lat)
        d_lat = (self.vn * dt) / 111139.0
        cos_lat = math.cos(math.radians(self.lat))
        d_lon = (self.ve * dt) / (111139.0 * max(cos_lat, 0.01))

        self.lat += d_lat
        self.lon += d_lon

        # 4. Covariance growth during dead reckoning
        if not self.gnss_active:
            self.pos_var += (0.05 * 0.05) * dt
            self.vel_var += (0.02 * 0.02) * dt
        else:
            self.pos_var = 3.0
            self.vel_var = 0.05

    def update_gnss(self, lat: float, lon: float, accuracy: float, speed: float, heading_deg: float):
        """Fuses GNSS anchor fix into filter state."""
        self.lat = lat
        self.lon = lon
        self.heading = math.radians(heading_deg)
        self.vn = speed * math.cos(self.heading)
        self.ve = speed * math.sin(self.heading)
        self.gnss_active = True
        self.pos_var = max(accuracy * accuracy, 1.0)

    def update_ai_velocity(self, v_ai: float):
        """Applies AI ensemble velocity observation to bound velocity drift."""
        cos_h = math.cos(self.heading)
        sin_h = math.sin(self.heading)
        # Soft blend (Kalman-like gain)
        cur_speed = math.sqrt(self.vn * self.vn + self.ve * self.ve)
        fused_speed = 0.75 * cur_speed + 0.25 * v_ai
        self.vn = fused_speed * cos_h
        self.ve = fused_speed * sin_h


ekf_state = HighRateEkfState()

# ---------------------------------------------------------------------------
# API Schemas
# ---------------------------------------------------------------------------
class ImuSample200Hz(BaseModel):
    timestamp: float
    ax: float = Field(..., description="Forward acceleration in m/s^2")
    ay: float = Field(..., description="Lateral acceleration in m/s^2")
    az: float = Field(..., description="Vertical acceleration in m/s^2")
    gx: float = Field(..., description="Roll rate in rad/s")
    gy: float = Field(..., description="Pitch rate in rad/s")
    gz: float = Field(..., description="Yaw rate in rad/s")

class BatchStream200HzRequest(BaseModel):
    sensor_grade: str = Field("FOG", description="'FOG' (Fiber Optic Gyro) or 'MEMS'")
    samples: List[ImuSample200Hz] = Field(..., description="Batch of high-rate IMU samples (e.g. 20-200 samples)")
    gnss_latitude: Optional[float] = None
    gnss_longitude: Optional[float] = None
    gnss_speed: Optional[float] = None
    gnss_heading: Optional[float] = None
    gnss_accuracy: Optional[float] = None

class EdgeNavResponse(BaseModel):
    latitude: float
    longitude: float
    velocity_mps: float
    velocity_kmh: float
    heading_deg: float
    uncertainty_m: float
    active_model: str
    status: str
    processing_latency_ms: float
    effective_rate_hz: float

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/")
def root():
    return RedirectResponse(url="/docs")

@app.get("/api/v1/health")
def health_check():
    return {
        "status": "HEALTHY",
        "engine": "IDR Edge High-Rate 200Hz Engine",
        "models": {
            "gru_available": gru_model is not None,
            "xgboost_available": xgb_regressor is not None,
            "architecture": "Regime-Based Ensemble (GRU <5m/s, XGBoost >=5m/s)",
        },
        "supported_frequencies_hz": [50, 100, 200],
        "sensor_grades": ["MEMS (Smartphone/Automotive)", "FOG (Tactical/Fiber Optic)"]
    }

@app.post("/api/v1/stream_200hz", response_model=EdgeNavResponse)
async def process_200hz_stream(req: BatchStream200HzRequest):
    import time
    t0 = time.perf_counter()

    if not req.samples:
        raise HTTPException(status_code=400, detail="Empty sample batch")

    # 1. Update GNSS if present
    if req.gnss_latitude is not None and req.gnss_longitude is not None:
        ekf_state.update_gnss(
            lat=req.gnss_latitude,
            lon=req.gnss_longitude,
            accuracy=req.gnss_accuracy or 3.0,
            speed=req.gnss_speed or 0.0,
            heading_deg=req.gnss_heading or 0.0,
        )
    else:
        ekf_state.gnss_active = False

    # 2. High-rate IMU Propagation at up to 200Hz
    for s in req.samples:
        dt = 0.005  # default 200Hz step
        if ekf_state.last_timestamp > 0:
            step_dt = s.timestamp - ekf_state.last_timestamp
            if 0 < step_dt < 0.1:
                dt = step_dt
        ekf_state.last_timestamp = s.timestamp

        ekf_state.predict(
            dt=dt,
            ax=s.ax,
            ay=s.ay,
            az=s.az,
            gx=s.gx,
            gy=s.gy,
            gz=s.gz,
        )

    # 3. AI Ensemble Velocity Update (computed over latest 20-sample window)
    active_regime = "Kinematic Integration"
    if len(req.samples) >= 20 and xgb_regressor is not None:
        # Build 20-step window from last 20 samples
        recent = req.samples[-20:]
        raw_window = np.zeros((20, 12), dtype=np.float32)
        for i, sample in enumerate(recent):
            raw_window[i] = [
                sample.ax, sample.ay, sample.az,
                0.0, 0.0, 9.81,
                sample.gx, sample.gy, sample.gz,
                math.degrees(ekf_state.heading), math.degrees(ekf_state.pitch), math.degrees(ekf_state.roll)
            ]

        # Extract features for XGBoost
        raw_feats = window_to_features(raw_window[np.newaxis, :, :])
        v_xgb = float(np.maximum(0.0, xgb_regressor.predict(raw_feats)[0]))

        if v_xgb < 5.0 and gru_model is not None and norm_params is not None:
            # Route to GRU
            Xn = (raw_window - np.array(norm_params["means"])) / np.array(norm_params["stds"])
            with torch.no_grad():
                inp = torch.tensor(Xn[np.newaxis, :, :], dtype=torch.float32).to(DEVICE)
                v_gru_t, stat_t = gru_model(inp)
                v_gru = float(max(0.0, v_gru_t.item()))
                stat_prob = float(torch.sigmoid(stat_t).item())
                if stat_prob > 0.90:
                    v_gru = 0.0
            v_fused = v_gru
            active_regime = "GRU (<5 m/s)"
        else:
            v_fused = v_xgb
            active_regime = "XGBoost (>=5 m/s)"

        ekf_state.update_ai_velocity(v_fused)

    t1 = time.perf_counter()
    latency_ms = (t1 - t0) * 1000.0

    current_speed = math.sqrt(ekf_state.vn * ekf_state.vn + ekf_state.ve * ekf_state.ve)

    return EdgeNavResponse(
        latitude=ekf_state.lat,
        longitude=ekf_state.lon,
        velocity_mps=current_speed,
        velocity_kmh=current_speed * 3.6,
        heading_deg=math.degrees(ekf_state.heading) % 360.0,
        uncertainty_m=math.sqrt(max(ekf_state.pos_var, 0.1)),
        active_model=active_regime,
        status="GNSS_LOCKED" if ekf_state.gnss_active else "DEAD_RECKONING_FUSED",
        processing_latency_ms=latency_ms,
        effective_rate_hz=float(len(req.samples)) / max(0.001, (req.samples[-1].timestamp - req.samples[0].timestamp)) if len(req.samples) > 1 else 200.0,
    )

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
