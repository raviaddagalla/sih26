from fastapi import FastAPI, HTTPException
from fastapi.responses import RedirectResponse
from pydantic import BaseModel
import torch
import numpy as np
import sys
from pathlib import Path
import math

# Adjust sys path to import our PyTorch models
sys.path.append(str(Path(__file__).resolve().parent.parent / "src"))
from models_lib import VelocityCNNSetC

app = FastAPI(
    title="Intelligent Dead Reckoning (IDR) Edge Engine",
    description="Edge-deployable software engine for AI-ML based dead reckoning and GNSS fusion.",
    version="1.0.0"
)

@app.get("/")
def root():
    """Redirect to the interactive API documentation."""
    return RedirectResponse(url="/docs")

# Load the trained model
DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
MODEL_PATH = Path(__file__).resolve().parent.parent / "models" / "cnn_roadsens" / "model.pt"

try:
    model = VelocityCNNSetC(in_channels=6).to(DEVICE)
    model.load_state_dict(torch.load(MODEL_PATH, map_location=DEVICE))
    model.eval()
    print("AI Model loaded successfully on edge engine.")
except Exception as e:
    print(f"Warning: Could not load model from {MODEL_PATH}. Error: {e}")
    model = None

# In-memory tracking state
class TrackingState:
    def __init__(self):
        self.latitude = 0.0
        self.longitude = 0.0
        self.heading = 0.0
        self.gnss_active = True

state = TrackingState()

# Pydantic schemas for the API
class SensorWindow(BaseModel):
    # Expects a 200x6 array: [acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z]
    imu_data: list[list[float]]
    gnss_latitude: float | None = None
    gnss_longitude: float | None = None
    dt: float = 1.0 # time elapsed since last window

class PositionResponse(BaseModel):
    latitude: float
    longitude: float
    velocity: float
    heading: float
    status: str

@app.post("/api/v1/sensor_stream", response_model=PositionResponse)
async def process_sensor_stream(data: SensorWindow):
    if len(data.imu_data) != 200 or len(data.imu_data[0]) != 6:
        raise HTTPException(status_code=400, detail="IMU data must be a 200x6 array.")
    
    # 1. GNSS+INS Fusion Logic
    if data.gnss_latitude is not None and data.gnss_longitude is not None:
        # We have GNSS signal! Snap to GNSS.
        state.latitude = data.gnss_latitude
        state.longitude = data.gnss_longitude
        state.gnss_active = True
        # In a real system, we'd also update the heading from GNSS course here
    else:
        state.gnss_active = False

    # 2. AI Velocity Estimation
    input_tensor = torch.tensor([data.imu_data], dtype=torch.float32).to(DEVICE)
    with torch.no_grad():
        if model is not None:
            velocity, _ = model(input_tensor)
            velocity = velocity.item()
        else:
            velocity = 0.0 # Fallback if model failed to load
            
    # 3. Heading Integration (Gyroscope Z-axis)
    # Get mean gyro_z from the last 100 samples (assuming 1 second stride)
    gyro_z_window = [row[5] for row in data.imu_data[-100:]]
    mean_wz = sum(gyro_z_window) / len(gyro_z_window)
    state.heading += mean_wz * data.dt
    
    # 4. Dead Reckoning Position Integration
    if not state.gnss_active:
        # Flat earth integration (1 degree lat ~= 111,139 meters)
        d_lat = (velocity * math.sin(state.heading) * data.dt) / 111139.0
        d_lon = (velocity * math.cos(state.heading) * data.dt) / (111139.0 * math.cos(math.radians(state.latitude)))
        
        state.latitude += d_lat
        state.longitude += d_lon
        
        # In the full system, RBPF Map Matching would be applied here to snap
        # the (state.latitude, state.longitude) onto the OpenStreetMap graph.

    return PositionResponse(
        latitude=state.latitude,
        longitude=state.longitude,
        velocity=velocity,
        heading=math.degrees(state.heading),
        status="GNSS_FUSED" if state.gnss_active else "DEAD_RECKONING"
    )

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
