"""
Export the A5 test trip as a JSON payload for the webapp simulation.
"""
import numpy as np
import pandas as pd
import json
from pathlib import Path

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
DATASET_ROOT = Path(r"D:\Nandhu\dead reckoning\IO-VNBD-master")
WEBAPP_MODEL_DIR = PROJECT_ROOT / "webapp" / "public" / "model"

WEBAPP_MODEL_DIR.mkdir(parents=True, exist_ok=True)

def export_sample():
    # Load A5 from test set
    test_data = np.load(PROCESSED_DIR / "test.npz")
    mask = test_data['trip_id'] == 'A5'
    X = test_data['X'][mask]
    
    with open(PROJECT_ROOT / "data" / "manifest.json", "r") as f:
        manifest = json.load(f)
        
    info = manifest['trips']['A5']
    s_path = DATASET_ROOT / info['s_file']
    s_df = pd.read_csv(s_path, encoding='latin-1')
    s_df.columns = [c.strip() for c in s_df.columns]
    
    lat_col = [c for c in s_df.columns if 'latitude' in c.lower()][0]
    lon_col = [c for c in s_df.columns if 'longitude' in c.lower()][0]
    head_col = [c for c in s_df.columns if 'orientation' in c.lower() and 'gps' in c.lower()][0]
    
    lats = pd.to_numeric(s_df[lat_col], errors='coerce').values
    lons = pd.to_numeric(s_df[lon_col], errors='coerce').values
    heads = pd.to_numeric(s_df[head_col], errors='coerce').values
    
    # Simple interpolation to match windows
    indices = np.linspace(0, len(lats)-1, len(X)).astype(int)
    gt_lats = lats[indices]
    gt_lons = lons[indices]
    gt_heads = heads[indices]
    
    start_lat = gt_lats[0]
    start_lon = gt_lons[0]
    start_head = gt_heads[0]
    
    # Set C indices: Linear Accel (0,1,2), Gyro (6,7,8)
    indices_c = [0, 1, 2, 6, 7, 8]
    X_c = X[:, :, indices_c]
    
    with open(PROCESSED_DIR / "norm_params.json", "r") as f:
        norm = json.load(f)
    
    means = np.array(norm['means'])[indices_c]
    stds = np.array(norm['stds'])[indices_c]
    
    X_raw = X_c * stds + means
    
    payload = {
        "initial_coords": [float(start_lat), float(start_lon)],
        "initial_heading": float(start_head),
        "windows": X_raw.tolist(),
        "gt_lats": gt_lats.tolist(),
        "gt_lons": gt_lons.tolist()
    }
    
    out_path = WEBAPP_MODEL_DIR / "sample_trip.json"
    with open(out_path, "w") as f:
        json.dump(payload, f)
        
    print(f"Exported sample trip to {out_path}")

if __name__ == "__main__":
    export_sample()
