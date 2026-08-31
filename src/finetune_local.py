import argparse
import json
import torch
import torch.nn as nn
from torch.utils.data import TensorDataset, DataLoader
import pandas as pd
import numpy as np
from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

import dataset
import models_lib

DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

def load_local_data(csv_path, norm_params, feature_indices=None):
    print(f"Loading local data from {csv_path}...")
    df = pd.read_csv(csv_path)
    # Use dataset to build windows
    windows = dataset.build_trip_windows(df, "local_trip")
    
    X = torch.tensor(windows['raw'], dtype=torch.float32)
    y = torch.tensor(windows['vel'], dtype=torch.float32)
    
    means = torch.tensor(norm_params['means'], dtype=torch.float32)
    stds = torch.tensor(norm_params['stds'], dtype=torch.float32)
    
    # Normalize X
    X = (X - means) / stds
    
    # Slice features
    if feature_indices:
        X = X[:, :, feature_indices]
        
    return X, y

def finetune(base_model_id, csv_path):
    with open(PROJECT_ROOT / "model_registry.json", "r") as f:
        registry = json.load(f)
        
    if base_model_id not in registry:
        raise ValueError(f"Model {base_model_id} not found in registry.")
        
    meta = registry[base_model_id]
    model_type = meta["model_type"]
    in_channels = len(meta["features"])
    
    print(f"Loading base model {base_model_id} ({model_type})...")
    
    # Instantiate architecture
    ModelClass = getattr(models_lib, model_type)
    model = ModelClass(in_channels=in_channels).to(DEVICE)
    
    # Load weights
    model_path = Path(meta["artifact_path"])
    model.load_state_dict(torch.load(model_path, map_location=DEVICE))
    
    # Freeze layers
    for name, param in model.named_parameters():
        if "fc2" not in name and "fc_stat" not in name:
            param.requires_grad = False
        else:
            param.requires_grad = True
            print(f"  Unfrozen layer: {name}")
            
    # Load norm params
    # In a real scenario we'd use the key, but we know it's corrected_v1
    with open(PROJECT_ROOT / "data" / "processed" / "norm_params.json", "r") as f:
        norm_params = json.load(f)
        
    # Map feature names to indices (0-11)
    all_features = norm_params['channels']
    feature_indices = [all_features.index(f) for f in meta["features"]]
        
    X, y = load_local_data(csv_path, norm_params, feature_indices)
    train_loader = DataLoader(TensorDataset(X, y), batch_size=32, shuffle=True)
    
    optimizer = torch.optim.Adam(filter(lambda p: p.requires_grad, model.parameters()), lr=1e-4)
    bce_criterion = nn.BCEWithLogitsLoss()
    
    print("Fine-tuning for 15 epochs...")
    model.train()
    for epoch in range(15):
        epoch_loss = 0.0
        for X_b, y_b in train_loader:
            X_b, y_b = X_b.to(DEVICE), y_b.to(DEVICE)
            optimizer.zero_grad()
            
            vel_preds, stat_logits = model(X_b)
            vel_loss = torch.mean((vel_preds - y_b)**2)
            
            y_stat = (y_b < 0.2).float()
            stat_loss = bce_criterion(stat_logits, y_stat)
            
            loss = vel_loss + 0.1 * stat_loss
            loss.backward()
            optimizer.step()
            epoch_loss += loss.item() * X_b.size(0)
            
        print(f"  Epoch {epoch+1:02d} | Loss: {epoch_loss/len(X):.4f}")
        
    # Save finetuned model
    new_id = f"{base_model_id}-india-finetuned"
    out_dir = PROJECT_ROOT / "models" / new_id
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{new_id}.pt"
    
    torch.save(model.state_dict(), out_path)
    
    # Update registry
    new_meta = meta.copy()
    new_meta["model_id"] = new_id
    new_meta["version"] = f"{new_id}_v1"
    new_meta["artifact_path"] = str(out_path)
    new_meta["note"] = "Fine-tuned on local Indian CSV data. Convolutional/Recurrent layers frozen."
    
    registry[new_id] = new_meta
    with open(PROJECT_ROOT / "model_registry.json", "w") as f:
        json.dump(registry, f, indent=2)
        
    print(f"\nSuccessfully saved fine-tuned model to {out_path}")
    print(f"Registered as {new_id} in model_registry.json")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-model", type=str, required=True, help="Base model ID from registry")
    parser.add_argument("--data", type=str, required=True, help="Path to local proxy CSV")
    args = parser.parse_args()
    
    finetune(args.base_model, args.data)
