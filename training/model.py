"""
VelocityCNN Model Architecture
Matches the on-device TFLite model:
- Input shape: [batch, 6, 200] (channels-first: ax, ay, az, gx, gy, gz; 200 samples = 2.0s at 100 Hz)
- Multi-task output:
    1. forward velocity (m/s) [regression]
    2. stationary probability logit [binary classification]
"""

import torch
import torch.nn as nn

class VelocityCNN(nn.Module):
    def __init__(self, in_channels: int = 6, seq_len: int = 200):
        super().__init__()
        self.in_channels = in_channels
        self.seq_len = seq_len

        # Feature extractor: 1D Temporal Convolutions
        self.conv1 = nn.Conv1d(in_channels, 32, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(32, 64, kernel_size=3, padding=1)
        self.relu = nn.ReLU()

        # Shared representation
        self.fc1 = nn.Linear(64, 64)
        self.dropout = nn.Dropout(0.2)

        # Multi-task heads:
        # Head 1: Forward velocity regression (m/s)
        self.fc2 = nn.Linear(64, 1)
        # Head 2: Stationary detection logit
        self.fc_stat = nn.Linear(64, 1)

    def forward(self, x: torch.Tensor):
        """
        Input x shape: [batch, 6, 200] or [batch, 200, 6]
        """
        # If input is channels-last [batch, seq_len, channels], permute to channels-first [batch, channels, seq_len]
        if x.shape[1] != self.in_channels and x.shape[2] == self.in_channels:
            x = x.permute(0, 2, 1)

        # 1D Temporal Convolutions
        feat = self.relu(self.conv1(x))
        feat = self.relu(self.conv2(feat))

        # Global average pooling over time dimension (dim=2)
        pooled = feat.mean(dim=2)

        # Dense feature projection
        h = self.dropout(self.relu(self.fc1(pooled)))

        # Output predictions
        velocity = self.fc2(h).squeeze(-1)
        stationary_logit = self.fc_stat(h).squeeze(-1)

        return velocity, stationary_logit


if __name__ == '__main__':
    model = VelocityCNN(in_channels=6, seq_len=200)
    dummy_input = torch.randn(2, 6, 200)
    vel, stat = model(dummy_input)
    print(f"Model successfully built.")
    print(f"Input: {dummy_input.shape}")
    print(f"Velocity output: {vel.shape}")
    print(f"Stationary logit output: {stat.shape}")
