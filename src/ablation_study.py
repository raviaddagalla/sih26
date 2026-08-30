"""
Ablation Study (Phase 2):
1. Feature Set Ablation: Evaluate CNN performance on Feature Sets A through E.
2. Mounting Robustness: Evaluate CNN performance with injected synthetic rotations (0 to 90 degrees).
"""
import torch
import torch.nn as nn
from torch.utils.data import TensorDataset, DataLoader
import numpy as np
import json
from pathlib import Path
from models import VelocityCNN
import time
from scipy.spatial.transform import Rotation

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
RESULTS_DIR = PROJECT_ROOT / "results"
CHECKPOINT_DIR = RESULTS_DIR / "model_checkpoints"

DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
BATCH_SIZE = 128

with open(PROJECT_ROOT / "data" / "manifest.json", "r") as f:
    manifest = json.load(f)

# Load normalization params to get channel indices
with open(PROCESSED_DIR / "norm_params.json", "r") as f:
    norm_params = json.load(f)
channel_names = norm_params['channels']


def load_data():
    train = np.load(PROCESSED_DIR / "train.npz")
    val = np.load(PROCESSED_DIR / "val.npz")

    return (
        train['X'], train['y'],
        val['X'], val['y']
    )


def train_and_eval(X_train, y_train, X_val, y_val, in_channels, name):
    print(f"\nEvaluating {name} ({in_channels} channels)...")
    
    train_loader = DataLoader(
        TensorDataset(torch.tensor(X_train, dtype=torch.float32), 
                      torch.tensor(y_train, dtype=torch.float32)), 
        batch_size=BATCH_SIZE, shuffle=True
    )
    val_loader = DataLoader(
        TensorDataset(torch.tensor(X_val, dtype=torch.float32), 
                      torch.tensor(y_val, dtype=torch.float32)), 
        batch_size=BATCH_SIZE, shuffle=False
    )
    
    model = VelocityCNN(in_channels=in_channels).to(DEVICE)
    criterion = nn.MSELoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode='min', factor=0.5, patience=3)
    
    best_val_loss = float('inf')
    patience = 8
    epochs_no_improve = 0
    
    for epoch in range(50):  # Cap at 50 for ablation to save time
        model.train()
        for X_batch, y_batch in train_loader:
            X_batch, y_batch = X_batch.to(DEVICE), y_batch.to(DEVICE)
            optimizer.zero_grad()
            preds = model(X_batch)
            loss = criterion(preds, y_batch)
            loss.backward()
            optimizer.step()
            
        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for X_batch, y_batch in val_loader:
                X_batch, y_batch = X_batch.to(DEVICE), y_batch.to(DEVICE)
                preds = model(X_batch)
                val_loss += criterion(preds, y_batch).item() * X_batch.size(0)
                
        val_loss /= len(val_loader.dataset)
        scheduler.step(val_loss)
        
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            epochs_no_improve = 0
        else:
            epochs_no_improve += 1
            
        if epochs_no_improve >= patience:
            break
            
    rmse = np.sqrt(best_val_loss)
    print(f"  Best Val RMSE: {rmse*3.6:.2f} km/h")
    return rmse


def inject_rotation(X_val, degrees):
    """
    Inject a systematic rotation into the validation data.
    This simulates placing the phone in a mount that is tilted/rotated 
    relative to the vehicle frame.
    
    Since X_val is normalized, we must:
    1. Un-normalize
    2. Apply 3D rotation to the 3-axis vector channels
    3. Re-normalize
    """
    if degrees == 0:
        return X_val.copy()
        
    means = np.array(norm_params['means'])
    stds = np.array(norm_params['stds'])
    
    X_raw = X_val * stds + means
    X_rotated = X_raw.copy()
    
    # Create rotation matrix (e.g. rotation around Y axis - pitch)
    r = Rotation.from_euler('y', degrees, degrees=True)
    R_mat = r.as_matrix()  # 3x3
    
    # Indices for 3-axis sensors in our 12-channel setup
    # 0,1,2: Linear Accel
    # 3,4,5: Gravity
    # 6,7,8: Gyroscope
    # We rotate the first 9 channels (the physical 3D vectors)
    
    batch_size, seq_len, _ = X_raw.shape
    for i in range(batch_size):
        for j in range(seq_len):
            # Rotate Accel
            X_rotated[i, j, 0:3] = R_mat @ X_raw[i, j, 0:3]
            # Rotate Gravity
            X_rotated[i, j, 3:6] = R_mat @ X_raw[i, j, 3:6]
            # Rotate Gyro
            X_rotated[i, j, 6:9] = R_mat @ X_raw[i, j, 6:9]
            
    # Re-normalize
    return (X_rotated - means) / stds
    

def main():
    X_train_full, y_train, X_val_full, y_val = load_data()
    
    ablation_results = {}
    
    print("="*60)
    print("1. FEATURE SET ABLATION")
    print("="*60)
    
    for set_name, info in manifest['feature_sets'].items():
        # Map Accelerometer to Linear Accel (as saved by preprocess.py)
        mapped_channels = [c.replace('Accelerometer', 'Linear Accel') for c in info['channels']]
        # Get channel indices for this set
        indices = [channel_names.index(c) for c in mapped_channels]
        
        X_train_sub = X_train_full[:, :, indices]
        X_val_sub = X_val_full[:, :, indices]
        
        rmse = train_and_eval(X_train_sub, y_train, X_val_sub, y_val, len(indices), f"Set {set_name}")
        ablation_results[f"feature_set_{set_name}"] = float(rmse * 3.6)
        
    print("\n" + "="*60)
    print("2. MOUNTING ROBUSTNESS (Rotation Injection)")
    print("="*60)
    
    # Load the best full-channel CNN model
    model = VelocityCNN(in_channels=12).to(DEVICE)
    try:
        model.load_state_dict(torch.load(CHECKPOINT_DIR / "VelocityCNN.pt", weights_only=True))
    except FileNotFoundError:
        print("VelocityCNN.pt not found. Please run train_models.py first.")
        return
        
    model.eval()
    criterion = nn.MSELoss()
    
    angles = [0, 15, 30, 45, 90]
    
    for angle in angles:
        X_rot = inject_rotation(X_val_full, angle)
        
        val_loader = DataLoader(
            TensorDataset(torch.tensor(X_rot, dtype=torch.float32), 
                          torch.tensor(y_val, dtype=torch.float32)), 
            batch_size=BATCH_SIZE, shuffle=False
        )
        
        val_loss = 0.0
        with torch.no_grad():
            for X_batch, y_batch in val_loader:
                X_batch, y_batch = X_batch.to(DEVICE), y_batch.to(DEVICE)
                preds = model(X_batch)
                val_loss += criterion(preds, y_batch).item() * X_batch.size(0)
                
        rmse = np.sqrt(val_loss / len(val_loader.dataset))
        print(f"  Angle {angle:2d}°: RMSE = {rmse*3.6:6.2f} km/h")
        ablation_results[f"rotation_{angle}deg"] = float(rmse * 3.6)
        
    with open(RESULTS_DIR / "ablation_results.json", "w") as f:
        json.dump(ablation_results, f, indent=2)
    print(f"\nSaved results to {RESULTS_DIR / 'ablation_results.json'}")

if __name__ == "__main__":
    main()
