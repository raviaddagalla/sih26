import torch
from pathlib import Path
import sys

sys.path.append(r"D:\Nandhu\dead reckoning\idr-project\src")
from models_lib import VelocityCNNSetC

MODEL_DIR = Path(r"D:\Nandhu\dead reckoning\idr-project\models\cnn_roadsens")
ONNX_PATH = MODEL_DIR / "model.onnx"

def convert():
    print("Loading PyTorch model...")
    model = VelocityCNNSetC(in_channels=6)
    model.load_state_dict(torch.load(MODEL_DIR / "model.pt", map_location='cpu'))
    model.eval()

    # Create dummy input with shape [1, 200, 6] (batch, seq_len, channels)
    dummy_input = torch.randn(1, 200, 6, requires_grad=True)

    print("Exporting to ONNX...")
    torch.onnx.export(
        model, 
        dummy_input, 
        ONNX_PATH, 
        export_params=True, 
        opset_version=13, 
        do_constant_folding=True, 
        input_names=['input'], 
        output_names=['velocity_out', 'stationary_out']
    )
    print(f"Exported to {ONNX_PATH}")

if __name__ == '__main__':
    convert()
