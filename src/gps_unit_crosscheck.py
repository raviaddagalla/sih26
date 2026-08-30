"""
Per-trip GPS Speed vs CAN Velocity cross-check.
For each trip with both S-file and V-file, compare:
  - GPS Speed raw max vs CAN Velocity max
  - GPS Speed * 3.6 vs CAN Velocity (tests "GPS is actually m/s" hypothesis)
  - GPS Speed / 3.6 vs CAN Velocity (tests "GPS is actually km/h and CAN is km/h" null hypothesis)
Also check A5/T2 (GPS-only) for internal consistency.
"""
import pandas as pd
import numpy as np
import json
from pathlib import Path

DATASET_ROOT = Path(r"D:\Nandhu\dead reckoning\IO-VNBD-master")
PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")

with open(PROJECT_ROOT / "data" / "manifest.json", "r") as f:
    manifest = json.load(f)

print("=" * 90)
print("GPS SPEED UNIT CROSS-CHECK: Per-trip GPS Speed vs CAN Velocity")
print("=" * 90)
print()
print(f"{'Trip':<8} {'GPS col header':<22} {'GPS max':>8} {'GPS*3.6':>8} {'CAN max':>8} {'GPS/CAN':>8} {'GPS*3.6/CAN':>12} {'Verdict'}")
print("-" * 90)

results = {}

for trip_id, info in manifest['trips'].items():
    if info['split'] == 'stationary':
        continue

    s_path = DATASET_ROOT / info['s_file']
    if not s_path.exists():
        continue

    s_df = pd.read_csv(s_path, encoding='latin-1')
    s_df.columns = [c.strip() for c in s_df.columns]

    gps_col = None
    for c in s_df.columns:
        if 'gps speed' in c.lower():
            gps_col = c
            break

    if gps_col is None:
        print(f"{trip_id:<8} No GPS speed column found")
        continue

    gps_speed = pd.to_numeric(s_df[gps_col], errors='coerce').dropna()
    gps_max = gps_speed.max()
    gps_mean = gps_speed[gps_speed > 0.5].mean() if (gps_speed > 0.5).any() else 0
    gps_p95 = np.percentile(gps_speed[gps_speed > 0], 95) if (gps_speed > 0).any() else 0

    if info['has_can_velocity'] and info.get('v_file'):
        v_path = DATASET_ROOT / info['v_file']
        if not v_path.exists():
            print(f"{trip_id:<8} V-file missing")
            continue

        v_df = pd.read_csv(v_path, encoding='latin-1')
        v_df.columns = [c.strip() for c in v_df.columns]

        can_col = None
        for c in v_df.columns:
            cl = c.lower().strip()
            if cl in ['velocity (km/hr)', 'velocity(km/h)', 'velocity (km/h)']:
                can_col = c
                break

        if can_col is None:
            print(f"{trip_id:<8} No CAN velocity column matched")
            continue

        can_vel = pd.to_numeric(v_df[can_col], errors='coerce').dropna()
        can_max = can_vel.max()
        can_mean = can_vel[can_vel > 0.5].mean() if (can_vel > 0.5).any() else 0

        ratio_raw = gps_max / can_max if can_max > 0 else float('inf')
        ratio_scaled = (gps_max * 3.6) / can_max if can_max > 0 else float('inf')

        # Determine verdict
        if 0.85 < ratio_scaled < 1.15:
            verdict = "m/s (×3.6~=CAN)"
        elif 0.85 < ratio_raw < 1.15:
            verdict = "km/h (raw~=CAN)"
        else:
            verdict = f"UNCLEAR"

        print(f"{trip_id:<8} {gps_col:<22} {gps_max:>8.2f} {gps_max*3.6:>8.2f} {can_max:>8.2f} {ratio_raw:>8.3f} {ratio_scaled:>12.3f} {verdict}")

        results[trip_id] = {
            'gps_col_header': gps_col,
            'gps_max': float(gps_max),
            'gps_mean_moving': float(gps_mean),
            'gps_p95': float(gps_p95),
            'can_max': float(can_max),
            'can_mean_moving': float(can_mean),
            'ratio_raw': float(ratio_raw),
            'ratio_scaled': float(ratio_scaled),
            'verdict': verdict
        }
    else:
        # A5 / T2: no V-file
        results[trip_id] = {
            'gps_col_header': gps_col,
            'gps_max': float(gps_max),
            'gps_mean_moving': float(gps_mean),
            'gps_p95': float(gps_p95),
            'can_max': None,
            'verdict': 'NO_CAN_CROSSCHECK'
        }
        print(f"{trip_id:<8} {gps_col:<22} {gps_max:>8.2f} {gps_max*3.6:>8.2f} {'N/A':>8} {'N/A':>8} {'N/A':>12} NO V-FILE")

print()
print("=" * 90)
print("DETAILED MEAN-SPEED CROSS-CHECK (moving segments only, GPS>0.5)")
print("=" * 90)
print()
print(f"{'Trip':<8} {'GPS mean(mov)':>14} {'GPS*3.6 mean':>14} {'CAN mean(mov)':>14} {'Ratio(scaled)':>14}")
print("-" * 70)

for tid, r in results.items():
    if r.get('can_max') is not None:
        gm = r['gps_mean_moving']
        cm = r['can_mean_moving']
        ratio = (gm * 3.6) / cm if cm > 0 else float('inf')
        print(f"{tid:<8} {gm:>14.2f} {gm*3.6:>14.2f} {cm:>14.2f} {ratio:>14.3f}")

print()
print("=" * 90)
print("A5 / T2 ANALYSIS (no CAN ground truth)")
print("=" * 90)
print()

for tid in ['A5', 'T2']:
    info = manifest['trips'][tid]
    s_path = DATASET_ROOT / info['s_file']
    s_df = pd.read_csv(s_path, encoding='latin-1')
    s_df.columns = [c.strip() for c in s_df.columns]

    gps_col = [c for c in s_df.columns if 'gps speed' in c.lower()][0]
    gps = pd.to_numeric(s_df[gps_col], errors='coerce').dropna()

    print(f"--- {tid} ---")
    print(f"  Column header: '{gps_col}'")
    print(f"  N samples: {len(gps)}")
    print(f"  Max: {gps.max():.2f}")
    print(f"  If m/s -> km/h: {gps.max()*3.6:.1f} km/h")
    print(f"  If already km/h: {gps.max():.1f} km/h")
    print(f"  Mean (moving, >0.5): {gps[gps>0.5].mean():.2f}")
    print(f"  P95 (moving): {np.percentile(gps[gps>0], 95):.2f}")
    print(f"  Road types: {info.get('road_types', 'unknown')}")
    print()

    # Plausibility check: for 'mixed' urban driving, max speed
    # If m/s: max ~10-30 m/s = 36-108 km/h (plausible)
    # If km/h: max ~10-30 km/h = very slow, only plausible for heavy city traffic
    if gps.max() < 40:
        # Could be either unit at these low values
        # But compare with Vtb5/Vw4 patterns
        print(f"  Plausibility: max={gps.max():.1f}")
        print(f"    If m/s:  max speed = {gps.max()*3.6:.0f} km/h — plausible for mixed driving")
        print(f"    If km/h: max speed = {gps.max():.0f} km/h — unusually slow for any trip with motorway/mixed")
        print(f"  Phone model: {info.get('phone_model', 'unknown')}")
        print()

# Check if the S-file header unit label varies across trips
print("=" * 90)
print("GPS SPEED COLUMN HEADER COMPARISON ACROSS ALL TRIPS")
print("=" * 90)
for tid, info in manifest['trips'].items():
    s_path = DATASET_ROOT / info['s_file']
    if not s_path.exists():
        continue
    s_df = pd.read_csv(s_path, encoding='latin-1', nrows=1)
    s_df.columns = [c.strip() for c in s_df.columns]
    gps_cols = [c for c in s_df.columns if 'gps speed' in c.lower()]
    print(f"  {tid:<8}: {gps_cols}")
