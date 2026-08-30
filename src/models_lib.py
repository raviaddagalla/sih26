"""
Five velocity-estimation model families for the model shootout.

All models solve the SAME task: time-window of IMU -> vehicle velocity (m/s).

    MODEL A: CNN Baseline            (12-channel, faithful reproduction)
    MODEL B: Feature Set C CNN       (6-channel: Linear Accel + Gyro only)
    MODEL C: GRU                     (recurrent)
    MODEL D: TCN                     (dilated temporal convolutions)
    MODEL E: XGBoost                 (tree-based, engineered window features)

All neural models share the same convention:
    input (batch, seq_len, channels) as float32
    normalization applied externally (training statistics only)
    output (batch,) predicted velocity in m/s
"""
import torch
import torch.nn as nn
import numpy as np

def apply_random_rotation(X_norm, means, stds, max_angle_deg=15.0):
    """
    Applies a random 3D rotation to the IMU axes for data augmentation.
    X_norm: (B, seq_len, C) tensor (already normalized).
    means, stds: (C,) normalization tensors.
    """
    B, seq_len, C = X_norm.shape
    device = X_norm.device
    
    # Unnormalize
    X = X_norm * stds + means
    
    # Random Euler angles
    angles = (torch.rand(B, 3, device=device) * 2 - 1) * (max_angle_deg * np.pi / 180.0)
    cos_a = torch.cos(angles)
    sin_a = torch.sin(angles)
    
    # Rotation matrices
    R_x = torch.eye(3, device=device).unsqueeze(0).repeat(B, 1, 1)
    R_x[:, 1, 1] = cos_a[:, 0]
    R_x[:, 1, 2] = -sin_a[:, 0]
    R_x[:, 2, 1] = sin_a[:, 0]
    R_x[:, 2, 2] = cos_a[:, 0]
    
    R_y = torch.eye(3, device=device).unsqueeze(0).repeat(B, 1, 1)
    R_y[:, 0, 0] = cos_a[:, 1]
    R_y[:, 0, 2] = sin_a[:, 1]
    R_y[:, 2, 0] = -sin_a[:, 1]
    R_y[:, 2, 2] = cos_a[:, 1]
    
    R_z = torch.eye(3, device=device).unsqueeze(0).repeat(B, 1, 1)
    R_z[:, 0, 0] = cos_a[:, 2]
    R_z[:, 0, 1] = -sin_a[:, 2]
    R_z[:, 1, 0] = sin_a[:, 2]
    R_z[:, 1, 1] = cos_a[:, 2]
    
    R = torch.bmm(R_z, torch.bmm(R_y, R_x))
    X_aug = X.clone()
    
    def rotate_group(start_idx):
        vec = X[:, :, start_idx:start_idx+3].unsqueeze(-1)
        R_expanded = R.unsqueeze(1).expand(-1, seq_len, -1, -1)
        rot_vec = torch.matmul(R_expanded, vec).squeeze(-1)
        X_aug[:, :, start_idx:start_idx+3] = rot_vec

    rotate_group(0) # Accel
    if C == 12:
        rotate_group(3) # Gravity
        rotate_group(6) # Gyro
    elif C == 6:
        rotate_group(3) # Gyro
        
    # Re-normalize
    return (X_aug - means) / stds




# ---------------------------------------------------------------------------
# MODEL A — CNN BASELINE (12-channel)
# Faithful reproduction of the existing VelocityCNN used to establish the
# 26.8 km/h validation RMSE result.
# ---------------------------------------------------------------------------
class VelocityCNN(nn.Module):
    def __init__(self, in_channels=12):
        super().__init__()
        self.in_channels = in_channels
        self.conv1 = nn.Conv1d(in_channels, 32, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(32, 64, kernel_size=3, padding=1)
        self.fc1 = nn.Linear(64, 64)
        self.dropout = nn.Dropout(0.2)
        # Velocity Regression Head
        self.fc2 = nn.Linear(64, 1)
        # Stationary Classification Head
        self.fc_stat = nn.Linear(64, 1)

    def forward(self, x):
        x = x.permute(0, 2, 1)
        x = torch.relu(self.conv1(x))
        x = torch.relu(self.conv2(x))
        x = x.mean(dim=2)
        x = torch.relu(self.fc1(x))
        x = self.dropout(x)
        vel = self.fc2(x).squeeze(-1)
        stat_logit = self.fc_stat(x).squeeze(-1)
        return vel, stat_logit


# ---------------------------------------------------------------------------
# MODEL B — FEATURE SET C CNN (6-channel: Linear Accel + Gyro)
# ---------------------------------------------------------------------------
class VelocityCNNSetC(VelocityCNN):
    def __init__(self, in_channels=6):
        super().__init__(in_channels=in_channels)


# ---------------------------------------------------------------------------
# MODEL C — GRU (recurrent)
# Small recurrent network tuned for a small dataset / cross-phone generalization.
# ---------------------------------------------------------------------------
class VelocityGRU(nn.Module):
    def __init__(self, in_channels, hidden=48, num_layers=1, dropout=0.2):
        super().__init__()
        self.in_channels = in_channels
        self.gru = nn.GRU(
            input_size=in_channels,
            hidden_size=hidden,
            num_layers=num_layers,
            batch_first=True,
            dropout=dropout if num_layers > 1 else 0.0,
        )
        self.fc1 = nn.Linear(hidden, hidden)
        self.dropout = nn.Dropout(dropout)
        # Velocity Regression Head
        self.fc2 = nn.Linear(hidden, 1)
        # Stationary Classification Head
        self.fc_stat = nn.Linear(hidden, 1)

    def forward(self, x):
        x, _ = self.gru(x)
        x = x[:, -1, :]
        x = torch.relu(self.fc1(x))
        x = self.dropout(x)
        vel = self.fc2(x).squeeze(-1)
        stat_logit = self.fc_stat(x).squeeze(-1)
        return vel, stat_logit


# ---------------------------------------------------------------------------
# MODEL D — TCN (dilated temporal convolutions)
# Input (batch, seq_len, channels). Uses causal dilated 1D convolutions.
# Receptive field = 1 + sum(kernel-1)*dilation over layers. With kernel=3,
# dilations [1,2,4,8], receptive field = 1 + 2*(1+2+4+8) = 31 samples.
# ---------------------------------------------------------------------------
class CausalConv1dBlock(nn.Module):
    def __init__(self, in_c, out_c, kernel=3, dilation=1):
        super().__init__()
        self.conv = nn.Conv1d(in_c, out_c, kernel, dilation=dilation,
                              padding=(kernel - 1) * dilation)
        self.bn = nn.BatchNorm1d(out_c)

    def forward(self, x):
        # conv is causal because padding only on the left is not directly
        # available; instead we pad on the right and trim, keeping causality.
        x = self.conv(x)
        # remove trailing padding introduced by symmetric padding (causal):
        # padding=(kernel-1)*dilation pads both sides; keep only valid output.
        out = x[:, :, : x.shape[2] - (self.conv.kernel_size[0] - 1) * self.conv.dilation[0]]
        out = torch.relu(self.bn(out))
        return out


class VelocityTCN(nn.Module):
    def __init__(self, in_channels, num_channels=(16, 32, 64), kernel=3,
                 dilations=(1, 2, 4, 8)):
        super().__init__()
        self.in_channels = in_channels
        # One dilated causal block per dilation step, then final narrow blocks.
        layers = []
        # dilations list defines width change pattern
        prev = in_channels
        # grow: use num_channels cycling across the dilation blocks
        widths = [num_channels[i % len(num_channels)] for i in range(len(dilations))]
        for d, w in zip(dilations, widths):
            layers.append(CausalConv1dBlock(prev, w, kernel, d))
            prev = w
        # final refinement blocks
        for c in num_channels:
            if c == prev:
                continue
            layers.append(CausalConv1dBlock(prev, c, kernel, 1))
            prev = c
        self.net = nn.Sequential(*layers)
        self.final_channels = prev
        self.fc1 = nn.Linear(self.final_channels, 32)
        # Velocity Regression Head
        self.fc2 = nn.Linear(32, 1)
        # Stationary Classification Head
        self.fc_stat = nn.Linear(32, 1)

    def forward(self, x):
        x = x.permute(0, 2, 1)
        x = self.net(x)
        x = x.mean(dim=2)  # global pooling over (remaining) time
        x = torch.relu(self.fc1(x))
        vel = self.fc2(x).squeeze(-1)
        stat_logit = self.fc_stat(x).squeeze(-1)
        return vel, stat_logit

    def receptive_field(self):
        # 1 + sum over dilation blocks of (kernel-1)*dilation
        field = 1
        for d in self.net:
            if isinstance(d, CausalConv1dBlock):
                field += (d.conv.kernel_size[0] - 1) * d.conv.dilation[0]
        return field


# ---------------------------------------------------------------------------
# MODEL E — XGBoost engineered features
# Tabular: each temporal window converted into scalar statistics.
# ---------------------------------------------------------------------------
def window_to_features(X, raw_inputs=False):
    """
    Convert a batch of windows (N, seq_len, n_ch) into engineered scalar
    features. Operates on RAW (unnormalized) IMU in canonical channel order:

        [0]=Linear Accel X, [1]=Y, [2]=Z,
        [3]=Gravity X, [4]=Y, [5]=Z,
        [6]=Gyro Yaw, [7]=Pitch, [8]=Roll
        (channels 9-11 Orientation excluded from feature set)

    No future information, no target, no GPS.

    Returns (N, n_features) float array. Feature order is fixed and recorded
    in the model metadata so browser/offline use is consistent.
    """
    X = np.asarray(X, dtype=float)
    N = X.shape[0]
    # Work on 3-axis measurement groups (accel 0-2, gyro 6-8)
    ax, ay, az = X[:, :, 0], X[:, :, 1], X[:, :, 2]
    gx, gy, gz = X[:, :, 6], X[:, :, 7], X[:, :, 8]

    accel_mag = np.sqrt(ax ** 2 + ay ** 2 + az ** 2)
    gyro_mag = np.sqrt(gx ** 2 + gy ** 2 + gz ** 2)

    # ---- helper stats ----
    def stats(v):
        return np.stack([
            v.mean(axis=1), v.std(axis=1),
            v.min(axis=1), v.max(axis=1),
            np.percentile(v, 25, axis=1),
            np.percentile(v, 75, axis=1),
        ], axis=1)

    def rms(v):
        return np.sqrt(np.mean(v ** 2, axis=1))

    feats = []

    feats.append(stats(ax))
    feats.append(stats(ay))
    feats.append(stats(az))
    feats.append(stats(gx))
    feats.append(stats(gy))
    feats.append(stats(gz))
    feats.append(stats(accel_mag))
    feats.append(stats(gyro_mag))

    # Ranges (max - min)
    for v in (ax, ay, az, gx, gy, gz, accel_mag, gyro_mag):
        feats.append(v.max(axis=1)[:, None] - v.min(axis=1)[:, None])

    # RMS of each axis + magnitudes
    for v in (ax, ay, az, gx, gy, gz, accel_mag, gyro_mag):
        feats.append(rms(v)[:, None])

    # jerk-ish: first differences
    for v in (ax, ay, az, gx, gy, gz):
        d = np.diff(v, axis=1)
        feats.append(np.mean(np.abs(d), axis=1)[:, None])
        feats.append(np.max(np.abs(d), axis=1)[:, None])

    # temporal slope/trend (least-squares slope over time idx, normalized)
    t = np.arange(X.shape[1], dtype=float)
    t -= t.mean()
    denom = np.sum(t * t)
    for v in (ax, ay, az, gx, gy, gz, accel_mag, gyro_mag):
        slope = (v - v.mean(axis=1, keepdims=True)) @ t / denom
        feats.append(slope[:, None])

    Xfeat = np.concatenate(feats, axis=1)
    return Xfeat.astype(np.float32)


FEATURE_NAMES = [
    'ax_mean', 'ax_std', 'ax_min', 'ax_max', 'ax_p25', 'ax_p75',
    'ay_mean', 'ay_std', 'ay_min', 'ay_max', 'ay_p25', 'ay_p75',
    'az_mean', 'az_std', 'az_min', 'az_max', 'az_p25', 'az_p75',
    'gx_mean', 'gx_std', 'gx_min', 'gx_max', 'gx_p25', 'gx_p75',
    'gy_mean', 'gy_std', 'gy_min', 'gy_max', 'gy_p25', 'gy_p75',
    'gz_mean', 'gz_std', 'gz_min', 'gz_max', 'gz_p25', 'gz_p75',
    'amag_mean', 'amag_std', 'amag_min', 'amag_max', 'amag_p25', 'amag_p75',
    'gmag_mean', 'gmag_std', 'gmag_min', 'gmag_max', 'gmag_p25', 'gmag_p75',
    'ax_range', 'ay_range', 'az_range', 'gx_range', 'gy_range', 'gz_range',
    'amag_range', 'gmag_range',
    'ax_rms', 'ay_rms', 'az_rms', 'gx_rms', 'gy_rms', 'gz_rms',
    'amag_rms', 'gmag_rms',
    'ax_jerk_mean', 'ax_jerk_max', 'ay_jerk_mean', 'ay_jerk_max',
    'az_jerk_mean', 'az_jerk_max', 'gx_jerk_mean', 'gx_jerk_max',
    'gy_jerk_mean', 'gy_jerk_max', 'gz_jerk_mean', 'gz_jerk_max',
    'ax_slope', 'ay_slope', 'az_slope', 'gx_slope', 'gy_slope', 'gz_slope',
    'amag_slope', 'gmag_slope',
]

if __name__ == "__main__":
    # Quick sanity check of all models
    X = torch.randn(4, 20, 12)
    models = {
        "cnn_baseline": VelocityCNN(in_channels=12),
        "cnn_feature_c": VelocityCNNSetC(in_channels=6),
        "gru": VelocityGRU(in_channels=12),
        "tcn": VelocityTCN(in_channels=12),
    }
    for name, m in models.items():
        n = sum(p.numel() for p in m.parameters())
        out = m(X if name != "cnn_feature_c" else X[:, :, [0, 1, 2, 6, 7, 8]])
        print(f"{name}: params={n:,}, out={tuple(out.shape)} (m/s)")
    tcn = VelocityTCN(in_channels=12)
    print(f"TCN receptive field: {tcn.receptive_field()} samples")
    # XGBoost features
    xf = window_to_features(X.numpy())
    print(f"window_to_features: {xf.shape}, FEATURE_NAMES len={len(FEATURE_NAMES)}")
    assert xf.shape[1] == len(FEATURE_NAMES)
    print("All models OK")
