import os
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import TensorDataset, DataLoader
import numpy as np
from pathlib import Path
import sys

sys.path.append(r"D:\Nandhu\dead reckoning\idr-project\src")
from models_lib import VelocityCNNSetC

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
MODELS_DIR = PROJECT_ROOT / "models" / "cnn_roadsens"

DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

def train():
    os.makedirs(MODELS_DIR, exist_ok=True)
    
    print("Loading train_roadsens.npz...")
    data = np.load(PROCESSED_DIR / "train_roadsens.npz")
    X, y = data['X'], data['y']
    
    # Filter out NaNs if any slipped through
    valid_mask = ~np.isnan(y)
    X = X[valid_mask]
    y = y[valid_mask]
    
    # Validation split (last 10% of train set)
    val_split = int(len(X) * 0.9)
    X_train, y_train = X[:val_split], y[:val_split]
    X_val, y_val = X[val_split:], y[val_split:]
    
    train_dataset = TensorDataset(torch.tensor(X_train, dtype=torch.float32), torch.tensor(y_train, dtype=torch.float32))
    val_dataset = TensorDataset(torch.tensor(X_val, dtype=torch.float32), torch.tensor(y_val, dtype=torch.float32))
    
    train_loader = DataLoader(train_dataset, batch_size=64, shuffle=True)
    val_loader = DataLoader(val_dataset, batch_size=64, shuffle=False)
    
    model = VelocityCNNSetC(in_channels=6).to(DEVICE)
    criterion = nn.MSELoss()
    optimizer = optim.Adam(model.parameters(), lr=1e-3)
    
    best_val_loss = float('inf')
    epochs = 100
    
    print("Starting training...")
    for epoch in range(epochs):
        model.train()
        train_loss = 0
        for batch_X, batch_y in train_loader:
            batch_X, batch_y = batch_X.to(DEVICE), batch_y.to(DEVICE)
            
            optimizer.zero_grad()
            vel_pred, _ = model(batch_X)
            loss = criterion(vel_pred, batch_y)
            loss.backward()
            optimizer.step()
            
            train_loss += loss.item()
            
        model.eval()
        val_loss = 0
        with torch.no_grad():
            for batch_X, batch_y in val_loader:
                batch_X, batch_y = batch_X.to(DEVICE), batch_y.to(DEVICE)
                vel_pred, _ = model(batch_X)
                loss = criterion(vel_pred, batch_y)
                val_loss += loss.item()
                
        train_loss /= len(train_loader)
        val_loss /= len(val_loader)
        
        if epoch % 10 == 0:
            print(f"Epoch {epoch}: Train Loss: {train_loss:.4f} | Val Loss: {val_loss:.4f}")
            
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            torch.save(model.state_dict(), MODELS_DIR / "model.pt")
            
    print(f"Training finished! Best Val Loss: {best_val_loss:.4f}")
    
if __name__ == "__main__":
    train()
