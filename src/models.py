"""
Velocity estimation models — readable source (Phase 2).
Architectures confirmed from bytecode analysis of the original .pyc files.
"""
import torch
import torch.nn as nn


class VelocityCNN(nn.Module):
    """
    1D-CNN for velocity estimation from IMU windows.
    Architecture: Conv1d(32,k=3,pad=same) -> ReLU -> Conv1d(64,k=3,pad=same) -> ReLU
                  -> GlobalAvgPool1d -> FC(64) -> ReLU -> Dropout(0.2) -> FC(1)
    Input: (batch, seq_len=20, channels=12)
    Output: (batch,) — predicted velocity in m/s
    """
    def __init__(self, in_channels=12):
        super().__init__()
        self.conv1 = nn.Conv1d(in_channels, 32, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(32, 64, kernel_size=3, padding=1)
        self.fc1 = nn.Linear(64, 64)
        self.dropout = nn.Dropout(0.2)
        self.fc2 = nn.Linear(64, 1)

    def forward(self, x):
        # x: (batch, seq_len, channels) -> permute to (batch, channels, seq_len)
        x = x.permute(0, 2, 1)
        x = torch.relu(self.conv1(x))
        x = torch.relu(self.conv2(x))
        x = x.mean(dim=2)  # Global average pooling over seq_len
        x = torch.relu(self.fc1(x))
        x = self.dropout(x)
        x = self.fc2(x)
        return x.squeeze(-1)


class VelocityLSTM(nn.Module):
    """
    2-layer LSTM for velocity estimation from IMU windows.
    Architecture: LSTM(64, return_sequences=True) -> LSTM(32) -> FC(32) -> ReLU -> FC(1)
    Input: (batch, seq_len=20, channels=12)
    Output: (batch,) — predicted velocity in m/s
    """
    def __init__(self, in_channels=12):
        super().__init__()
        self.lstm1 = nn.LSTM(input_size=in_channels, hidden_size=64, batch_first=True)
        self.lstm2 = nn.LSTM(input_size=64, hidden_size=32, batch_first=True)
        self.fc1 = nn.Linear(32, 32)
        self.fc2 = nn.Linear(32, 1)

    def forward(self, x):
        # x: (batch, seq_len, channels)
        x, _ = self.lstm1(x)       # (batch, seq_len, 64)
        x, _ = self.lstm2(x)       # (batch, seq_len, 32)
        x = x[:, -1, :]            # Take last timestep: (batch, 32)
        x = torch.relu(self.fc1(x))
        x = self.fc2(x)
        return x.squeeze(-1)
