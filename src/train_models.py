"""
Train the VelocityCNN and VelocityLSTM models on the corrected dataset (Phase 2).
Reports val RMSE alongside the naive baseline (predicting the mean).
"""
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import TensorDataset, DataLoader
import numpy as np
import json
from pathlib import Path
from models import VelocityCNN, VelocityLSTM
import time

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
RESULTS_DIR = PROJECT_ROOT / "results"
CHECKPOINT_DIR = RESULTS_DIR / "model_checkpoints"

CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
(RESULTS_DIR / "tables").mkdir(parents=True, exist_ok=True)

# Hyperparameters
BATCH_SIZE = 128
EPOCHS = 1000
PATIENCE = 15
LR = 1e-3
DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')


def load_data():
    print("Loading data...")
    train = np.load(PROCESSED_DIR / "train.npz")
    val = np.load(PROCESSED_DIR / "val.npz")

    X_train = torch.tensor(train['X'], dtype=torch.float32)
    y_train = torch.tensor(train['y'], dtype=torch.float32)
    X_val = torch.tensor(val['X'], dtype=torch.float32)
    y_val = torch.tensor(val['y'], dtype=torch.float32)

    train_loader = DataLoader(TensorDataset(X_train, y_train), batch_size=BATCH_SIZE, shuffle=True)
    val_loader = DataLoader(TensorDataset(X_val, y_val), batch_size=BATCH_SIZE, shuffle=False)

    return train_loader, val_loader, y_train.numpy(), y_val.numpy()


def train_model(model_name, model, train_loader, val_loader):
    print(f"\n{'='*50}\nTraining {model_name} on {DEVICE}\n{'='*50}")
    model = model.to(DEVICE)
    criterion = nn.MSELoss()
    optimizer = optim.Adam(model.parameters(), lr=LR)
    scheduler = optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode='min', factor=0.5, patience=5)

    best_val_loss = float('inf')
    epochs_no_improve = 0
    best_model_path = CHECKPOINT_DIR / f"{model_name}.pt"

    start_time = time.time()

    for epoch in range(1, EPOCHS + 1):
        # Train
        model.train()
        train_loss = 0.0
        for X_batch, y_batch in train_loader:
            X_batch, y_batch = X_batch.to(DEVICE), y_batch.to(DEVICE)

            optimizer.zero_grad()
            preds = model(X_batch)
            loss = criterion(preds, y_batch)
            loss.backward()
            optimizer.step()
            train_loss += loss.item() * X_batch.size(0)
        train_loss /= len(train_loader.dataset)
        train_rmse = np.sqrt(train_loss)

        # Validate
        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for X_batch, y_batch in val_loader:
                X_batch, y_batch = X_batch.to(DEVICE), y_batch.to(DEVICE)
                preds = model(X_batch)
                loss = criterion(preds, y_batch)
                val_loss += loss.item() * X_batch.size(0)
        val_loss /= len(val_loader.dataset)
        val_rmse = np.sqrt(val_loss)

        scheduler.step(val_loss)

        if val_loss < best_val_loss:
            best_val_loss = val_loss
            epochs_no_improve = 0
            torch.save(model.state_dict(), best_model_path)
            print(f"Epoch {epoch:3d}: Train RMSE = {train_rmse*3.6:6.2f} km/h | Val RMSE = {val_rmse*3.6:6.2f} km/h  (Best)")
        else:
            epochs_no_improve += 1
            if epoch % 5 == 0 or epochs_no_improve == PATIENCE:
                print(f"Epoch {epoch:3d}: Train RMSE = {train_rmse*3.6:6.2f} km/h | Val RMSE = {val_rmse*3.6:6.2f} km/h")

        if epochs_no_improve >= PATIENCE:
            print(f"Early stopping at epoch {epoch}")
            break

    elapsed = time.time() - start_time
    best_val_rmse = np.sqrt(best_val_loss)
    print(f"Training completed in {elapsed:.1f}s")
    print(f"Best Val RMSE: {best_val_rmse*3.6:.2f} km/h ({best_val_rmse:.2f} m/s)")
    return best_val_rmse


def evaluate_naive_baseline(y_train, y_val):
    """
    The naive baseline predicts the mean velocity of the training set
    for every sample in the validation set.
    """
    mean_vel = np.mean(y_train)
    naive_preds = np.full_like(y_val, fill_value=mean_vel)
    naive_mse = np.mean((y_val - naive_preds)**2)
    naive_rmse = np.sqrt(naive_mse)
    return naive_rmse, mean_vel


def main():
    train_loader, val_loader, y_train, y_val = load_data()

    # Calculate naive baseline
    naive_rmse, mean_vel = evaluate_naive_baseline(y_train, y_val)
    print("\n" + "="*50)
    print("NAIVE BASELINE (Predicting Train Mean)")
    print("="*50)
    print(f"Train Mean Velocity: {mean_vel*3.6:.2f} km/h ({mean_vel:.2f} m/s)")
    print(f"Val Naive RMSE:      {naive_rmse*3.6:.2f} km/h ({naive_rmse:.2f} m/s)")

    # Train CNN
    cnn_model = VelocityCNN(in_channels=12)
    cnn_rmse = train_model("VelocityCNN", cnn_model, train_loader, val_loader)

    # Train LSTM
    lstm_model = VelocityLSTM(in_channels=12)
    lstm_rmse = train_model("VelocityLSTM", lstm_model, train_loader, val_loader)

    # Compile results
    results = {
        "naive_baseline_rmse_kmh": float(naive_rmse * 3.6),
        "cnn_val_rmse_kmh": float(cnn_rmse * 3.6),
        "lstm_val_rmse_kmh": float(lstm_rmse * 3.6),
        "cnn_improvement_over_naive_pct": float((naive_rmse - cnn_rmse) / naive_rmse * 100),
        "lstm_improvement_over_naive_pct": float((naive_rmse - lstm_rmse) / naive_rmse * 100)
    }

    print("\n" + "="*50)
    print("FINAL COMPARISON")
    print("="*50)
    print(f"Naive Baseline RMSE: {results['naive_baseline_rmse_kmh']:.2f} km/h")
    print(f"CNN Val RMSE:        {results['cnn_val_rmse_kmh']:.2f} km/h (Improves {results['cnn_improvement_over_naive_pct']:.1f}%)")
    print(f"LSTM Val RMSE:       {results['lstm_val_rmse_kmh']:.2f} km/h (Improves {results['lstm_improvement_over_naive_pct']:.1f}%)")

    with open(RESULTS_DIR / "model_comparison.json", "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nSaved results to {RESULTS_DIR / 'model_comparison.json'}")


if __name__ == "__main__":
    main()
