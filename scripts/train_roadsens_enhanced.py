import os
import sys
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import TensorDataset, DataLoader
import numpy as np
from pathlib import Path

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
sys.path.append(str(PROJECT_ROOT / "src"))
from models_lib import EnhancedVelocityResGRU, apply_random_rotation

PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
MODELS_DIR = PROJECT_ROOT / "models" / "cnn_roadsens_enhanced"

DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

def train():
    os.makedirs(MODELS_DIR, exist_ok=True)
    print(f"Using device: {DEVICE}", flush=True)
    print("Loading train_roadsens.npz...", flush=True)
    data = np.load(PROCESSED_DIR / "train_roadsens.npz")
    X, y = data['X'], data['y']
    
    # Filter out NaNs
    valid_mask = ~np.isnan(y)
    X = X[valid_mask]
    y = y[valid_mask]
    
    val_split = int(len(X) * 0.9)
    X_train, y_train = X[:val_split], y[:val_split]
    X_val, y_val = X[val_split:], y[val_split:]
    
    # Binary stationary target: speed < 0.2 m/s (~0.7 km/h)
    stat_train = (y_train < 0.2).astype(np.float32)
    stat_val = (y_val < 0.2).astype(np.float32)
    
    # Normalization parameters for batch rotation augmentation
    means = torch.tensor(np.mean(X_train, axis=(0, 1)), dtype=torch.float32, device=DEVICE)
    stds = torch.tensor(np.std(X_train, axis=(0, 1)) + 1e-6, dtype=torch.float32, device=DEVICE)
    
    train_dataset = TensorDataset(
        torch.tensor(X_train, dtype=torch.float32),
        torch.tensor(y_train, dtype=torch.float32),
        torch.tensor(stat_train, dtype=torch.float32)
    )
    val_dataset = TensorDataset(
        torch.tensor(X_val, dtype=torch.float32),
        torch.tensor(y_val, dtype=torch.float32),
        torch.tensor(stat_val, dtype=torch.float32)
    )
    
    train_loader = DataLoader(train_dataset, batch_size=64, shuffle=True)
    val_loader = DataLoader(val_dataset, batch_size=64, shuffle=False)
    
    model = EnhancedVelocityResGRU(in_channels=6, hidden=64, num_layers=1, dropout=0.2).to(DEVICE)
    
    # Robust Huber loss (SmoothL1) + BCEWithLogits for stationary detection
    criterion_vel = nn.SmoothL1Loss(beta=0.5)
    criterion_stat = nn.BCEWithLogitsLoss()
    
    optimizer = optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)
    epochs = 35
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs, eta_min=1e-5)
    
    best_val_loss = float('inf')
    
    print(f"Training EnhancedVelocityResGRU for {epochs} epochs...", flush=True)
    
    for epoch in range(epochs):
        model.train()
        train_loss = 0.0
        train_mae = 0.0
        
        for batch_X, batch_y, batch_stat in train_loader:
            batch_X = batch_X.to(DEVICE)
            batch_y = batch_y.to(DEVICE)
            batch_stat = batch_stat.to(DEVICE)
            
            # Vectorized batch 3D spatial rotation augmentation (50% prob)
            if torch.rand(1).item() > 0.5:
                batch_X = apply_random_rotation(batch_X, means, stds, max_angle_deg=10.0)
                
            optimizer.zero_grad()
            vel_pred, stat_logit = model(batch_X)
            
            # Huber velocity loss
            l_vel = criterion_vel(vel_pred, batch_y)
            # Stationary BCE loss
            l_stat = criterion_stat(stat_logit, batch_stat)
            # Explicit stationary zero-clamp penalty: when stopped (stat==1), penalize any positive velocity
            stat_mask = (batch_stat > 0.5)
            if stat_mask.sum() > 0:
                l_zero_clamp = criterion_vel(vel_pred[stat_mask], torch.zeros_like(vel_pred[stat_mask]))
            else:
                l_zero_clamp = 0.0
                
            loss = l_vel + 0.3 * l_stat + 1.0 * l_zero_clamp
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=2.0)
            optimizer.step()
            
            train_loss += loss.item()
            train_mae += torch.mean(torch.abs(vel_pred - batch_y)).item()
            
        scheduler.step()
        train_loss /= len(train_loader)
        train_mae /= len(train_loader)
        
        # Validation
        model.eval()
        val_loss = 0.0
        val_mae = 0.0
        
        with torch.no_grad():
            for batch_X, batch_y, batch_stat in val_loader:
                batch_X = batch_X.to(DEVICE)
                batch_y = batch_y.to(DEVICE)
                batch_stat = batch_stat.to(DEVICE)
                
                vel_pred, stat_logit = model(batch_X)
                stat_prob = torch.sigmoid(stat_logit)
                vel_clamped = torch.where(stat_prob > 0.5, torch.zeros_like(vel_pred), vel_pred)
                
                l_vel = criterion_vel(vel_clamped, batch_y)
                l_stat = criterion_stat(stat_logit, batch_stat)
                val_loss += (l_vel + 0.3 * l_stat).item()
                val_mae += torch.mean(torch.abs(vel_clamped - batch_y)).item()
                
        val_loss /= len(val_loader)
        val_mae /= len(val_loader)
        
        if epoch % 5 == 0 or epoch == epochs - 1:
            print(f"Epoch {epoch:02d} | Train Loss: {train_loss:.4f} MAE: {train_mae:.4f} m/s | Val Loss: {val_loss:.4f} MAE: {val_mae:.4f} m/s", flush=True)
            
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            torch.save(model.state_dict(), MODELS_DIR / "model.pt")
            
    print(f"Training Complete! Best Val Loss: {best_val_loss:.4f}", flush=True)
    print(f"Model saved to {MODELS_DIR / 'model.pt'}", flush=True)

if __name__ == "__main__":
    train()
