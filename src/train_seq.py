import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import TensorDataset, DataLoader
import numpy as np
import os
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
import common
from models_lib import StatefulGRU

def load_data():
    path = common.PROCESSED_DIR / "dataset_seq.npz"
    d = np.load(path)
    X_train, y_train = d['X_train'], d['y_train']
    X_val, y_val = d['X_val'], d['y_val']
    seq_len = X_train.shape[1]
    
    # Compute normalization stats
    # Flatten across batch and seq_len for mean/std
    X_flat = X_train.reshape(-1, 12)
    means = np.mean(X_flat, axis=0)
    stds = np.std(X_flat, axis=0)
    # prevent division by zero
    stds[stds < 1e-6] = 1.0

    X_train = (X_train - means) / stds
    X_val = (X_val - means) / stds

    return (
        torch.tensor(X_train, dtype=torch.float32),
        torch.tensor(y_train, dtype=torch.float32),
        torch.tensor(X_val, dtype=torch.float32),
        torch.tensor(y_val, dtype=torch.float32),
        torch.tensor(means, dtype=torch.float32),
        torch.tensor(stds, dtype=torch.float32),
        int(seq_len)
    )

def train():
    print("Loading data...")
    X_train, y_train, X_val, y_val, means, stds, seq_len = load_data()
    
    train_ds = TensorDataset(X_train, y_train)
    val_ds = TensorDataset(X_val, y_val)
    
    train_dl = DataLoader(train_ds, batch_size=32, shuffle=True)
    val_dl = DataLoader(val_ds, batch_size=32, shuffle=False)
    
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    
    model = StatefulGRU(in_channels=12, hidden=64, num_layers=2).to(device)
    optimizer = optim.Adam(model.parameters(), lr=1e-3, weight_decay=1e-4)
    criterion = nn.MSELoss()
    
    print(f"Training StatefulGRU on {device}...")
    best_val_loss = float('inf')
    
    epochs = 40
    for epoch in range(epochs):
        model.train()
        train_loss = 0.0
        for X_b, y_b in train_dl:
            X_b, y_b = X_b.to(device), y_b.to(device)
            optimizer.zero_grad()
            
            # Forward pass: h=None means it starts with zeros for each sequence
            pred_vel, _ = model(X_b)
            loss = criterion(pred_vel, y_b)
            
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            train_loss += loss.item() * X_b.size(0)
            
        train_loss /= len(train_ds)
        
        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for X_b, y_b in val_dl:
                X_b, y_b = X_b.to(device), y_b.to(device)
                pred_vel, _ = model(X_b)
                loss = criterion(pred_vel, y_b)
                val_loss += loss.item() * X_b.size(0)
                
        val_loss /= len(val_ds)
        
        train_rmse = np.sqrt(train_loss) * 3.6
        val_rmse = np.sqrt(val_loss) * 3.6
        print(f"Epoch {epoch+1:02d}/{epochs} | Train RMSE: {train_rmse:.2f} km/h | Val RMSE: {val_rmse:.2f} km/h")
        
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            
            # Save model
            save_dir = common.MODELS_DIR / "stateful_gru"
            save_dir.mkdir(parents=True, exist_ok=True)
            
            torch.save(model.state_dict(), save_dir / "model.pt")
            
            # Save metadata
            meta = {
                "in_channels": 12,
                "seq_len": seq_len,
                "means": means.tolist(),
                "stds": stds.tolist(),
                "val_rmse_kmh": float(val_rmse)
            }
            with open(save_dir / "metadata.json", "w") as f:
                json.dump(meta, f, indent=2)

if __name__ == "__main__":
    train()
