"""
Export PyTorch weights to a simple JSON format for TensorFlow.js.
Also copies norm_params.json to the webapp/public/model folder.
"""
import torch
import json
import shutil
from pathlib import Path
from models_lib import VelocityCNNSetC

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
CHECKPOINT_DIR = PROJECT_ROOT / "models" / "cnn_feature_c_lowspeed"
WEBAPP_MODEL_DIR = PROJECT_ROOT / "webapp" / "public" / "model"

WEBAPP_MODEL_DIR.mkdir(parents=True, exist_ok=True)

def export_model():
    print("Loading PyTorch model...")
    model = VelocityCNNSetC(in_channels=6)
    model.load_state_dict(torch.load(CHECKPOINT_DIR / "cnn_feature_c_lowspeed.pt", map_location='cpu', weights_only=True))
    model.eval()

    # Extract weights
    weights = {}
    
    # In TF.js: conv1d weights are [kernel_size, in_channels, out_channels]
    # PyTorch: conv1d weights are [out_channels, in_channels, kernel_size]
    
    # conv1
    w = model.conv1.weight.detach().numpy() # [32, 12, 3]
    w = w.transpose(2, 1, 0) # [3, 12, 32]
    weights['conv1/kernel'] = w.tolist()
    weights['conv1/bias'] = model.conv1.bias.detach().numpy().tolist()
    
    # conv2
    w = model.conv2.weight.detach().numpy() # [64, 32, 3]
    w = w.transpose(2, 1, 0) # [3, 32, 64]
    weights['conv2/kernel'] = w.tolist()
    weights['conv2/bias'] = model.conv2.bias.detach().numpy().tolist()
    
    # fc1 (PyTorch Linear is [out, in])
    w = model.fc1.weight.detach().numpy() # [64, 64]
    w = w.transpose(1, 0) # [64, 64]
    weights['fc1/kernel'] = w.tolist()
    weights['fc1/bias'] = model.fc1.bias.detach().numpy().tolist()
    
    # fc2 (Velocity Regression)
    w = model.fc2.weight.detach().numpy() # [1, 64]
    w = w.transpose(1, 0) # [64, 1]
    weights['fc2/kernel'] = w.tolist()
    weights['fc2/bias'] = model.fc2.bias.detach().numpy().tolist()

    # fc_stat (Stationary Classification)
    w = model.fc_stat.weight.detach().numpy() # [1, 64]
    w = w.transpose(1, 0) # [64, 1]
    weights['fc_stat/kernel'] = w.tolist()
    weights['fc_stat/bias'] = model.fc_stat.bias.detach().numpy().tolist()
    
    # Save weights
    out_path = WEBAPP_MODEL_DIR / "model_weights.json"
    with open(out_path, "w") as f:
        json.dump(weights, f)
        
    print(f"Weights exported to {out_path}")
    
    # Copy norm_params.json
    src_norm = PROJECT_ROOT / "data" / "processed" / "norm_params.json"
    dst_norm = WEBAPP_MODEL_DIR / "norm_params.json"
    shutil.copy(src_norm, dst_norm)
    print(f"Norm params copied to {dst_norm}")

if __name__ == "__main__":
    export_model()
