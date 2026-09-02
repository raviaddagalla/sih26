import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import TensorDataset, DataLoader
import numpy as np
from pathlib import Path
import sys

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
sys.path.append(str(PROJECT_ROOT / "src"))

from models_lib import StatefulCNNGRU

def train_iovnbd():
    print("Loading IO-VNBD data (6 channels: accel + gyro)...")
    train_data = np.load(PROCESSED_DIR / "iovnbd_train.npz")
    test_data = np.load(PROCESSED_DIR / "iovnbd_test.npz")
    
    X_train = torch.tensor(train_data['X'], dtype=torch.float32)
    y_train = torch.tensor(train_data['y'], dtype=torch.float32)
    
    X_test = torch.tensor(test_data['X'], dtype=torch.float32)
    y_test = torch.tensor(test_data['y'], dtype=torch.float32)
    
    train_loader = DataLoader(TensorDataset(X_train, y_train), batch_size=32, shuffle=True)
    test_loader = DataLoader(TensorDataset(X_test, y_test), batch_size=32, shuffle=False)
    
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"Using device: {device}")
    
    # StatefulCNNGRU adapted for 6 channels (raw dashboard accel + gyro)
    model = StatefulCNNGRU(in_channels=6, cnn_channels=32, hidden=64, num_layers=2).to(device)
    
    optimizer = optim.Adam(model.parameters(), lr=1e-3)
    criterion = nn.MSELoss()
    
    epochs = 20
    best_val_loss = float('inf')
    
    print("Starting Domain Retraining on IO-VNBD...")
    
    for epoch in range(epochs):
        model.train()
        train_loss = 0.0
        for X_batch, y_batch in train_loader:
            X_batch, y_batch = X_batch.to(device), y_batch.to(device)
            optimizer.zero_grad()
            
            preds, _ = model(X_batch)
            preds = preds.mean(dim=1) # average velocity over the window
            
            loss = criterion(preds, y_batch)
            loss.backward()
            optimizer.step()
            
            train_loss += loss.item() * len(X_batch)
            
        train_loss /= len(train_loader.dataset)
        
        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for X_batch, y_batch in test_loader:
                X_batch, y_batch = X_batch.to(device), y_batch.to(device)
                preds, _ = model(X_batch)
                preds = preds.mean(dim=1)
                loss = criterion(preds, y_batch)
                val_loss += loss.item() * len(X_batch)
                
        val_loss /= len(test_loader.dataset)
        
        print(f"Epoch [{epoch+1}/{epochs}] Train MSE: {train_loss:.4f} | Val MSE: {val_loss:.4f} (RMSE: {np.sqrt(val_loss):.2f} m/s)")
        
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            torch.save(model.state_dict(), PROCESSED_DIR / "best_iovnbd_model.pth")
            
    print("Training complete! Best model saved.")

if __name__ == "__main__":
    train_iovnbd()
