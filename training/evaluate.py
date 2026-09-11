"""
VelocityCNN and IDR Trajectory Evaluation Harness
Evaluates VelocityCNN model on held-out IO-VNBD sequence,
computes drift benchmarks per SIH / competition targets,
and generates publication-quality plots:
1. Speed profile (Predicted vs Ground Truth)
2. 2D Dead Reckoning Trajectory vs Ground Truth Trajectory
"""

import os
import sys
import json
import argparse
from pathlib import Path
import numpy as np
import pandas as pd
import torch
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_DATA_PATH = PROJECT_ROOT / "app_updated" / "app" / "assets" / "demo" / "test_dataset.csv"
NORM_PARAMS_PATH = PROJECT_ROOT / "app_updated" / "app" / "assets" / "models" / "norm_params.json"
PLOTS_DIR = SCRIPT_DIR / "evaluation_plots"
PLOTS_DIR.mkdir(parents=True, exist_ok=True)

from model import VelocityCNN


def load_dataset(csv_path: Path):
    df = pd.read_csv(csv_path)
    return df


def evaluate_sequence(df: pd.DataFrame, model_path: Path = None):
    # Load normalization statistics
    with open(NORM_PARAMS_PATH, 'r') as f:
        params = json.load(f)
    means = np.array(params['means'], dtype=np.float32)
    stds = np.array(params['stds'], dtype=np.float32)

    imu_cols = ['accel_x', 'accel_y', 'accel_z', 'gyro_x', 'gyro_y', 'gyro_z']
    raw_imu = df[imu_cols].values.astype(np.float32)
    norm_imu = (raw_imu - means) / stds

    gt_speeds = df['gt_speed'].values.astype(np.float32) if 'gt_speed' in df.columns else df['gnss_speed'].values.astype(np.float32)
    gt_headings = df['gt_heading'].values.astype(np.float32) if 'gt_heading' in df.columns else np.zeros(len(df), dtype=np.float32)

    n_samples = len(df)
    window_size = 200

    # Check if TFLite model is available
    tflite_file = PROJECT_ROOT / "app_updated" / "app" / "assets" / "models" / "velocity_cnn.tflite"
    use_tflite = (model_path is not None and str(model_path).endswith('.tflite')) or (model_path is None and tflite_file.exists())
    if use_tflite and model_path is None:
        model_path = tflite_file

    pred_speeds = np.zeros(n_samples, dtype=np.float32)
    stat_probs = np.zeros(n_samples, dtype=np.float32)
    pred_speeds[:window_size] = gt_speeds[:window_size]

    if use_tflite:
        import tensorflow as tf
        print(f"Loading on-device TFLite model: {model_path}")
        interp = tf.lite.Interpreter(model_path=str(model_path))
        interp.allocate_tensors()
        in_det = interp.get_input_details()[0]
        out_dets = interp.get_output_details()

        print("Running TFLite sequence inference...")
        for i in range(window_size, n_samples):
            win = norm_imu[i - window_size:i].T[np.newaxis, ...] # [1, 6, 200]
            interp.set_tensor(in_det['index'], win)
            interp.invoke()
            vel_val = float(interp.get_tensor(out_dets[0]['index'])[0])
            stat_val = float(interp.get_tensor(out_dets[1]['index'])[0])
            if stat_val > 0.85:
                vel_val = 0.0
            pred_speeds[i] = max(0.0, vel_val)
            stat_probs[i] = stat_val
    else:
        device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
        model = VelocityCNN(in_channels=6, seq_len=200).to(device)

        if model_path and model_path.exists():
            ckpt = torch.load(model_path, map_location=device)
            state_dict = ckpt.get('model_state_dict', ckpt)
            model.load_state_dict(state_dict)
            print(f"Loaded model weights from {model_path}")
        else:
            print("Note: Running with baseline VelocityCNN weights.")

        model.eval()
        batch_windows = []
        batch_indices = []
        batch_size = 128

        print("Running PyTorch sequence inference...")
        for i in range(window_size, n_samples):
            win = norm_imu[i - window_size:i].T # [6, 200]
            batch_windows.append(win)
            batch_indices.append(i)

            if len(batch_windows) >= batch_size or i == n_samples - 1:
                x_tensor = torch.tensor(np.array(batch_windows), dtype=torch.float32).to(device)
                with torch.no_grad():
                    vel_out, stat_out = model(x_tensor)
                    vel_arr = torch.clamp(vel_out, min=0.0).cpu().numpy()
                    stat_arr = torch.sigmoid(stat_out).cpu().numpy()

                for idx, (b_idx, v_pred, s_prob) in enumerate(zip(batch_indices, vel_arr, stat_arr)):
                    if s_prob > 0.85:
                        v_pred = 0.0
                    pred_speeds[b_idx] = v_pred
                    stat_probs[b_idx] = s_prob

                batch_windows.clear()
                batch_indices.clear()
                stat_probs[b_idx] = s_prob

            batch_windows.clear()
            batch_indices.clear()

    # Time array (dt = 0.01s for 100 Hz)
    dt = 0.01
    time_sec = np.arange(n_samples) * dt

    # 1. Metrics Evaluation
    eval_slice = slice(window_size, n_samples)
    eval_gt = gt_speeds[eval_slice]
    eval_pred = pred_speeds[eval_slice]

    rmse_ms = np.sqrt(np.mean((eval_pred - eval_gt) ** 2))
    mae_ms = np.mean(np.abs(eval_pred - eval_gt))
    rmse_kmh = rmse_ms * 3.6
    mae_kmh = mae_ms * 3.6

    ss_tot = np.sum((eval_gt - np.mean(eval_gt)) ** 2)
    ss_res = np.sum((eval_gt - eval_pred) ** 2)
    r2_score = 1.0 - (ss_res / max(1e-6, ss_tot))

    # 2. Trajectory Integration (Dead Reckoning)
    # Convert heading to radians (0 = North, pi/2 = East)
    heading_rad = np.radians(gt_headings)

    # Integrated coordinates: Ground Truth
    gt_vx = gt_speeds * np.cos(heading_rad)
    gt_vy = gt_speeds * np.sin(heading_rad)
    gt_x = np.cumsum(gt_vx * dt)
    gt_y = np.cumsum(gt_vy * dt)

    # Integrated coordinates: Dead Reckoning (AI Speed + Heading)
    dr_vx = eval_pred * np.cos(heading_rad[eval_slice])
    dr_vy = eval_pred * np.sin(heading_rad[eval_slice])
    dr_x = np.cumsum(dr_vx * dt)
    dr_y = np.cumsum(dr_vy * dt)

    total_dist_eval = float(np.sum(eval_gt * dt))
    final_error = float(np.sqrt((dr_x[-1] - (gt_x[-1] - gt_x[window_size])) ** 2 +
                                (dr_y[-1] - (gt_y[-1] - gt_y[window_size])) ** 2))
    drift_pct = (final_error / max(1.0, total_dist_eval)) * 100.0

    print("\n" + "=" * 60)
    print("      INTELLIGENT DEAD RECKONING BENCHMARK REPORT")
    print("=" * 60)
    print(f"Sequence Duration:           {time_sec[-1]:.1f} s ({time_sec[-1]/60.0:.2f} min)")
    print(f"Total Traveled Distance:     {total_dist_eval:.1f} m ({total_dist_eval/1000.0:.2f} km)")
    print(f"Velocity RMSE:               {rmse_ms:.3f} m/s ({rmse_kmh:.2f} km/h)")
    print(f"Velocity MAE:                {mae_ms:.3f} m/s ({mae_kmh:.2f} km/h)")
    print(f"Coefficient of Determ. (R²): {r2_score:.4f}")
    print(f"Dead Reckoning Final Drift:  {final_error:.2f} m")
    print(f"Drift Percentage:            {drift_pct:.2f}% (Target: < 10.0%)")

    # SIH Competition Benchmarks Check
    pass_10pct = drift_pct < 10.0
    pass_50m = final_error < 5.0 if total_dist_eval <= 100 else (final_error / total_dist_eval) * 50 < 5.0
    pass_1km = (final_error / max(1.0, total_dist_eval)) * 1000 < 100.0

    print("\n--- SIH Benchmark Verification ---")
    print(f" [PASS={pass_10pct}] Overall drift < 10% distance traveled: {drift_pct:.2f}%")
    print(f" [PASS={pass_50m}] Drift over 50m in <1 min (<5m target): {(final_error/total_dist_eval)*50:.2f} m")
    print(f" [PASS={pass_1km}] Drift over 1km at 60 km/h (<100m target): {(final_error/total_dist_eval)*1000:.2f} m")
    print("=" * 60)

    # 3. Plot Speed Comparison
    plt.figure(figsize=(12, 5), dpi=150)
    plt.plot(time_sec[eval_slice], eval_gt * 3.6, label='Ground Truth Speed', color='#10B981', lw=1.8)
    plt.plot(time_sec[eval_slice], eval_pred * 3.6, label='VelocityCNN Predicted Speed', color='#3B82F6', lw=1.5, alpha=0.85)
    plt.title(f"IO-VNBD Sequence Velocity Estimation | RMSE: {rmse_kmh:.2f} km/h, Drift: {drift_pct:.1f}%", fontsize=13, fontweight='bold')
    plt.xlabel("Time (seconds)", fontsize=11)
    plt.ylabel("Speed (km/h)", fontsize=11)
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.legend(frameon=True, facecolor='white', framealpha=0.9)
    plt.tight_layout()
    speed_plot_path = PLOTS_DIR / "speed_evaluation.png"
    plt.savefig(speed_plot_path)
    plt.close()
    print(f"\n[OK] Saved speed profile plot to: {speed_plot_path}")

    # 4. Plot 2D Position Trajectory
    plt.figure(figsize=(9, 8), dpi=150)
    gt_aligned_x = gt_x[eval_slice] - gt_x[window_size]
    gt_aligned_y = gt_y[eval_slice] - gt_y[window_size]

    plt.plot(gt_aligned_y, gt_aligned_x, label='Ground Truth Trajectory', color='#10B981', lw=2.5)
    plt.plot(dr_y, dr_x, label=f'Dead Reckoning Trajectory (Drift: {drift_pct:.1f}%)', color='#EF4444', lw=2.0, linestyle='--')
    plt.scatter([0], [0], color='#10B981', s=80, zorder=5, label='Start')
    plt.scatter([gt_aligned_y[-1]], [gt_aligned_x[-1]], color='#10B981', s=80, marker='X', zorder=5, label='End (GT)')
    plt.scatter([dr_y[-1]], [dr_x[-1]], color='#EF4444', s=80, marker='X', zorder=5, label='End (DR)')

    plt.title("2D Dead Reckoning Trajectory vs Ground Truth (GNSS Blackout)", fontsize=13, fontweight='bold')
    plt.xlabel("East Displacement (meters)", fontsize=11)
    plt.ylabel("North Displacement (meters)", fontsize=11)
    plt.grid(True, linestyle='--', alpha=0.5)
    plt.axis('equal')
    plt.legend(frameon=True, facecolor='white', framealpha=0.9)
    plt.tight_layout()
    traj_plot_path = PLOTS_DIR / "trajectory_evaluation.png"
    plt.savefig(traj_plot_path)
    plt.close()
    print(f"[OK] Saved 2D trajectory plot to: {traj_plot_path}")

    # Save summary report JSON
    report = {
        "sequence_duration_sec": float(time_sec[-1]),
        "total_distance_m": total_dist_eval,
        "velocity_rmse_ms": float(rmse_ms),
        "velocity_rmse_kmh": float(rmse_kmh),
        "velocity_mae_kmh": float(mae_kmh),
        "r2_score": float(r2_score),
        "drift_error_m": float(final_error),
        "drift_percentage": float(drift_pct),
        "benchmarks": {
            "drift_less_than_10_percent": bool(pass_10pct),
            "drift_under_5m_per_50m": bool(pass_50m),
            "drift_under_100m_per_1km": bool(pass_1km),
        }
    }
    with open(PLOTS_DIR / "evaluation_report.json", "w") as f:
        json.dump(report, f, indent=2)

    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Evaluate VelocityCNN on IO-VNBD sequence")
    parser.add_argument('--data', type=str, default=str(DEFAULT_DATA_PATH), help="Path to evaluation sequence CSV")
    parser.add_argument('--model', type=str, default=None,
                        help="Path to model (.tflite or .pt). Defaults to on-device velocity_cnn.tflite")
    args = parser.parse_args()

    df = load_dataset(Path(args.data))
    model_p = Path(args.model) if args.model else None
    evaluate_sequence(df, model_p)
