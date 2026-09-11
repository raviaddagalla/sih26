#!/usr/bin/env python3
"""
IDR Live Drive Session Plotter & Ground-Truth Benchmarking Tool
Analyzes and plots live vehicular telemetry logged by the IDR Flutter app.
Generates:
  1. 2D Trajectory: Fused IDR Path vs Raw GNSS Track with blackout highlights
  2. Filter Uncertainty: Sawtooth curve confirming covariance growth & reduction
  3. Speed Profiles: Fused vehicular speed vs Raw GPS speed
  4. SIH Competition Compliance Metrics: Drift error % (<10% threshold)
"""

import sys
import os
import argparse
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

def haversine_distance(lat1, lon1, lat2, lon2):
    """Compute Haversine distance in meters between two lat/lon coordinates."""
    R = 6371000.0
    phi1, phi2 = np.radians(lat1), np.radians(lat2)
    dphi = np.radians(lat2 - lat1)
    dlambda = np.radians(lon2 - lon1)
    a = np.sin(dphi / 2.0)**2 + np.cos(phi1) * np.cos(phi2) * np.sin(dlambda / 2.0)**2
    c = 2.0 * np.arctan2(np.sqrt(a), np.sqrt(1.0 - a))
    return R * c

def analyze_and_plot(csv_path, output_dir=None):
    if not os.path.isfile(csv_path):
        print(f"Error: File not found: {csv_path}")
        return False

    df = pd.read_csv(csv_path)
    print(f"[OK] Loaded session: {csv_path} ({len(df)} samples)")

    if output_dir is None:
        output_dir = os.path.dirname(csv_path) or "."
    os.makedirs(output_dir, exist_ok=True)

    rel_time = df['rel_time_s'].values
    fused_lat = df['fused_lat'].values
    fused_lon = df['fused_lon'].values
    fused_speed = df['fused_speed_kmh'].values
    uncertainty = df['position_uncertainty_m'].values
    nav_mode = df['nav_mode'].astype(str).values
    force_blocked = df['gnss_force_blocked'].values == 1

    # Raw GNSS coordinates (may contain NaNs during complete loss)
    raw_lat = pd.to_numeric(df['raw_gnss_lat'], errors='coerce').values
    raw_lon = pd.to_numeric(df['raw_gnss_lon'], errors='coerce').values
    raw_speed = pd.to_numeric(df['raw_gnss_speed_mps'], errors='coerce').values * 3.6

    is_dr = (nav_mode == 'deadReckoning') | force_blocked

    # Compute cumulative distance
    distances = [0.0]
    for i in range(1, len(fused_lat)):
        d = haversine_distance(fused_lat[i-1], fused_lon[i-1], fused_lat[i], fused_lon[i])
        distances.append(distances[-1] + d)
    total_distance_m = distances[-1]

    # Compute blackout segments and drift
    blackout_indices = np.where(is_dr)[0]
    max_blackout_sec = 0.0
    drift_at_reacq_m = 0.0
    blackout_dist_m = 0.0

    if len(blackout_indices) > 0:
        start_idx = blackout_indices[0]
        end_idx = blackout_indices[-1]
        max_blackout_sec = rel_time[end_idx] - rel_time[start_idx]
        blackout_dist_m = distances[end_idx] - distances[start_idx]

        # If raw GNSS is available at end of blackout (ground truth)
        if not np.isnan(raw_lat[end_idx]) and not np.isnan(raw_lon[end_idx]):
            drift_at_reacq_m = haversine_distance(
                fused_lat[end_idx], fused_lon[end_idx],
                raw_lat[end_idx], raw_lon[end_idx]
            )

    drift_pct = (drift_at_reacq_m / max(blackout_dist_m, 1.0)) * 100.0

    # -------------------------------------------------------------
    # Create 3-Panel Scientific Plot
    # -------------------------------------------------------------
    fig = plt.figure(figsize=(14, 10))
    gs = fig.add_gridspec(2, 2, height_ratios=[1.2, 1.0])

    # 1. Trajectory Map (Local XY in meters relative to start)
    ax_map = fig.add_subplot(gs[0, :])
    
    # Convert lat/lon to local NED meters
    origin_lat, origin_lon = fused_lat[0], fused_lon[0]
    fused_x = (fused_lon - origin_lon) * (111320.0 * np.cos(np.radians(origin_lat)))
    fused_y = (fused_lat - origin_lat) * 110540.0

    valid_raw = ~np.isnan(raw_lat) & ~np.isnan(raw_lon) & (raw_lat != 0.0)
    raw_x = (raw_lon[valid_raw] - origin_lon) * (111320.0 * np.cos(np.radians(origin_lat)))
    raw_y = (raw_lat[valid_raw] - origin_lat) * 110540.0

    ax_map.plot(raw_x, raw_y, 'g--', linewidth=2.0, alpha=0.7, label='Raw GNSS Fixes (Ground Truth)')
    ax_map.plot(fused_x, fused_y, 'b-', linewidth=2.5, label='IDR Fused Path (ESKF + CNN + NHC)')

    # Highlight Blackout segments
    if len(blackout_indices) > 0:
        ax_map.plot(fused_x[is_dr], fused_y[is_dr], 'r-', linewidth=3.5, label='GNSS Blackout Segment (Pure DR)')

    ax_map.scatter(fused_x[0], fused_y[0], color='green', s=120, zorder=5, label='Start')
    ax_map.scatter(fused_x[-1], fused_y[-1], color='red', marker='X', s=140, zorder=5, label='End')

    ax_map.set_title("Live In-Car Drive: Trajectory Tracking through GNSS Blackout", fontsize=13, fontweight='bold')
    ax_map.set_xlabel("East Offset (meters)", fontsize=10)
    ax_map.set_ylabel("North Offset (meters)", fontsize=10)
    ax_map.grid(True, linestyle=':', alpha=0.6)
    ax_map.legend(loc='best', framealpha=0.9)
    ax_map.axis('equal')

    # 2. Position Uncertainty (Sawtooth Filter Behavior)
    ax_unc = fig.add_subplot(gs[1, 0])
    ax_unc.plot(rel_time, uncertainty, color='#8b5cf6', linewidth=2.0, label='ESKF Position Uncertainty (1σ)')
    
    # Shade blackout regions
    in_blackout = False
    b_start = 0.0
    for i in range(len(rel_time)):
        if is_dr[i] and not in_blackout:
            in_blackout = True
            b_start = rel_time[i]
        elif not is_dr[i] and in_blackout:
            in_blackout = False
            ax_unc.axvspan(b_start, rel_time[i], color='red', alpha=0.15, label='Blackout Active' if i == blackout_indices[-1] else "")
    if in_blackout:
        ax_unc.axvspan(b_start, rel_time[-1], color='red', alpha=0.15)

    ax_unc.set_title("Covariance P Evolution: Sawtooth Growth & Fix Reduction", fontsize=11, fontweight='bold')
    ax_unc.set_xlabel("Time (seconds)", fontsize=9)
    ax_unc.set_ylabel("Uncertainty (meters)", fontsize=9)
    ax_unc.grid(True, linestyle=':', alpha=0.6)
    ax_unc.legend(loc='upper left', fontsize=8)

    # 3. Speed Profile Comparison
    ax_spd = fig.add_subplot(gs[1, 1])
    ax_spd.plot(rel_time, fused_speed, color='#0284c7', linewidth=1.8, label='IDR Fused Speed (km/h)')
    if np.any(valid_raw):
        ax_spd.plot(rel_time[valid_raw], raw_speed[valid_raw], color='#10b981', linestyle=':', linewidth=1.5, alpha=0.8, label='Raw GNSS Speed')

    ax_spd.set_title("Speed Estimation Stability", fontsize=11, fontweight='bold')
    ax_spd.set_xlabel("Time (seconds)", fontsize=9)
    ax_spd.set_ylabel("Speed (km/h)", fontsize=9)
    ax_spd.grid(True, linestyle=':', alpha=0.6)
    ax_spd.legend(loc='upper right', fontsize=8)

    plt.tight_layout()

    out_plot = os.path.join(output_dir, "live_session_analysis.png")
    plt.savefig(out_plot, dpi=200)
    plt.close()
    print(f"[OK] Saved analysis plot to: {out_plot}")

    # -------------------------------------------------------------
    # Print Benchmarking Summary Table
    # -------------------------------------------------------------
    print("\n" + "="*55)
    print("       IDR LIVE DRIVING BENCHMARK REPORT")
    print("="*55)
    print(f"Total Session Duration : {rel_time[-1]:.1f} seconds")
    print(f"Total Distance Traveled: {total_distance_m:.1f} meters ({total_distance_m/1000.0:.2f} km)")
    print(f"GNSS Blackout Duration : {max_blackout_sec:.1f} seconds")
    print(f"Distance during Outage : {blackout_dist_m:.1f} meters")
    print(f"Drift at Reacquisition : {drift_at_reacq_m:.2f} meters")
    print(f"Drift Percentage       : {drift_pct:.2f}% (Benchmark Target: <10%)")
    pass_status = "PASS (<10%)" if drift_pct < 10.0 else "REVIEW"
    print(f"Benchmark Status       : [{pass_status}]")
    print("="*55 + "\n")

    return True

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Analyze & Plot IDR Live Drive Session CSV")
    parser.add_argument("csv_path", help="Path to exported session CSV from IDR app")
    parser.add_argument("--output_dir", "-o", default=None, help="Directory to save generated plots")
    args = parser.parse_args()

    analyze_and_plot(args.csv_path, args.output_dir)
