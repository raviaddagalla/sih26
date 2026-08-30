"""
Phase 1 — Forensic analysis of the corrupted preprocessing pipeline.
This script:
1. Inspects every raw CSV for column names, GPS speed range, CAN velocity range
2. Checks for non-monotonic timestamps
3. Examines the corrupted .npz files to quantify the label corruption
4. Reports the root cause
"""
import pandas as pd
import numpy as np
import json
from pathlib import Path

DATASET_ROOT = Path(r"D:\Nandhu\dead reckoning\IO-VNBD-master")
PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")

with open(PROJECT_ROOT / "data" / "manifest.json", "r") as f:
    manifest = json.load(f)

print("=" * 80)
print("STEP 1: Per-trip raw CSV inspection")
print("=" * 80)

for trip_id, info in manifest['trips'].items():
    print(f"\n--- Trip: {trip_id} (split={info['split']}) ---")
    
    # Load S-file
    s_path = DATASET_ROOT / info['s_file']
    if not s_path.exists():
        print(f"  S-file NOT FOUND: {s_path}")
        continue
    s_df = pd.read_csv(s_path, encoding='latin-1')
    s_df.columns = [c.strip() for c in s_df.columns]
    print(f"  S-file columns ({len(s_df.columns)}): {list(s_df.columns)}")
    print(f"  S-file rows: {len(s_df)}")
    
    # Find GPS speed column
    gps_speed_col = None
    for c in s_df.columns:
        if 'gps speed' in c.lower() or 'gps_speed' in c.lower():
            gps_speed_col = c
            break
    
    if gps_speed_col:
        gps_speed = pd.to_numeric(s_df[gps_speed_col], errors='coerce')
        print(f"  GPS Speed column: '{gps_speed_col}'")
        print(f"    min={gps_speed.min():.2f}, max={gps_speed.max():.2f}, mean={gps_speed.mean():.2f}")
        print(f"    NaN count: {gps_speed.isna().sum()}")
        # Check units: GPS speed in IO-VNBD is typically km/h
        if gps_speed.max() > 200:
            print(f"    *** WARNING: GPS speed max > 200, possible unit issue ***")
    else:
        print(f"  *** No GPS Speed column found ***")
    
    # Find time column
    time_col = None
    for c in s_df.columns:
        if 'time since start' in c.lower():
            time_col = c
            break
    
    if time_col:
        time_vals = pd.to_numeric(s_df[time_col], errors='coerce')
        diffs = time_vals.diff()
        neg_diffs = diffs[diffs < 0]
        print(f"  Time column: '{time_col}'")
        print(f"    min={time_vals.min():.1f}, max={time_vals.max():.1f}")
        print(f"    Duration: {(time_vals.max() - time_vals.min()) / 1000:.1f} s")
        if len(neg_diffs) > 0:
            print(f"    *** NON-MONOTONIC TIMESTAMPS: {len(neg_diffs)} backward jumps ***")
            print(f"    Largest backward jump: {neg_diffs.min():.1f} ms")
            for idx in neg_diffs.index[:3]:
                print(f"      at row {idx}: {time_vals.iloc[idx-1]:.1f} -> {time_vals.iloc[idx]:.1f}")
        else:
            print(f"    Timestamps are monotonic: OK")
    
    # Load V-file if exists
    if info['has_can_velocity'] and info.get('v_file'):
        v_path = DATASET_ROOT / info['v_file']
        if v_path.exists():
            v_df = pd.read_csv(v_path, encoding='latin-1')
            v_df.columns = [c.strip() for c in v_df.columns]
            print(f"  V-file columns ({len(v_df.columns)}): {list(v_df.columns)}")
            print(f"  V-file rows: {len(v_df)}")
            
            # Find velocity column
            vel_col = None
            for c in v_df.columns:
                cl = c.lower().strip()
                # Be very specific to avoid matching "Vertical Velocity"
                if cl in ['velocity (km/hr)', 'velocity(km/h)', 'velocity (km/h)']:
                    vel_col = c
                    break
            
            if vel_col is None:
                # Fallback: look for any velocity column, print all candidates
                vel_candidates = [c for c in v_df.columns if 'velocity' in c.lower() or 'speed' in c.lower()]
                print(f"    Velocity column candidates: {vel_candidates}")
                if vel_candidates:
                    for vc in vel_candidates:
                        vals = pd.to_numeric(v_df[vc], errors='coerce')
                        print(f"      '{vc}': min={vals.min():.2f}, max={vals.max():.2f}, mean={vals.mean():.2f}")
            else:
                can_vel = pd.to_numeric(v_df[vel_col], errors='coerce')
                print(f"  CAN Velocity column: '{vel_col}'")
                print(f"    min={can_vel.min():.2f}, max={can_vel.max():.2f}, mean={can_vel.mean():.2f}")
                if can_vel.max() > 200:
                    print(f"    *** WARNING: CAN velocity max > 200, possible unit issue ***")
            
            # Check V-file time column
            v_time_col = None
            for c in v_df.columns:
                if 'time since start' in c.lower():
                    v_time_col = c
                    break
            if v_time_col:
                v_time = pd.to_numeric(v_df[v_time_col], errors='coerce')
                v_diffs = v_time.diff()
                v_neg = v_diffs[v_diffs < 0]
                print(f"  V-file time: min={v_time.min():.1f}, max={v_time.max():.1f}")
                if len(v_neg) > 0:
                    print(f"    *** NON-MONOTONIC: {len(v_neg)} backward jumps, largest={v_neg.min():.1f} ***")
        else:
            print(f"  V-file NOT FOUND: {v_path}")

print("\n\n")
print("=" * 80)
print("STEP 2: Examine corrupted .npz files")
print("=" * 80)

for split_name in ['train', 'val', 'test']:
    npz_path = PROJECT_ROOT / "data" / "processed" / f"{split_name}.npz"
    data = np.load(npz_path, allow_pickle=True)
    X = data['X']
    y = data['y']
    trip_ids = data['trip_id']
    
    print(f"\n--- {split_name}.npz ---")
    print(f"  X shape: {X.shape}")
    print(f"  y shape: {y.shape}")
    print(f"  y (m/s): min={y.min():.2f}, max={y.max():.2f}, mean={y.mean():.2f}, std={y.std():.2f}")
    y_kmh = y * 3.6
    print(f"  y (km/h): min={y_kmh.min():.2f}, max={y_kmh.max():.2f}, mean={y_kmh.mean():.2f}")
    print(f"  y > 200 km/h: {(y_kmh > 200).sum()} samples ({(y_kmh > 200).mean()*100:.1f}%)")
    print(f"  y > 150 km/h: {(y_kmh > 150).sum()} samples ({(y_kmh > 150).mean()*100:.1f}%)")
    print(f"  y < 0: {(y < 0).sum()} samples")
    
    # Per-trip breakdown
    unique_trips = np.unique(trip_ids)
    print(f"  Trips in split: {unique_trips}")
    for tid in unique_trips:
        mask = trip_ids == tid
        yt = y[mask]
        yt_kmh = yt * 3.6
        print(f"    {tid}: n={mask.sum()}, y_kmh min={yt_kmh.min():.1f}, max={yt_kmh.max():.1f}, mean={yt_kmh.mean():.1f}")

print("\n\n")
print("=" * 80)
print("STEP 3: Examine norm_params.json")
print("=" * 80)

with open(PROJECT_ROOT / "data" / "processed" / "norm_params.json", "r") as f:
    norm_params = json.load(f)

print("Channel normalization statistics:")
for i, (ch, m, s) in enumerate(zip(norm_params['channels'], norm_params['means'], norm_params['stds'])):
    flag = ""
    if 'Orientation' in ch:
        if abs(m) > 50 or s > 100:
            flag = " *** IMPLAUSIBLE ***"
    print(f"  [{i:2d}] {ch:25s}: mean={m:10.4f}, std={s:10.4f}{flag}")

print("\n\n")
print("=" * 80)
print("STEP 4: Root cause hypothesis testing")
print("=" * 80)

# Hypothesis A: km/h vs m/s mixing
# GPS speed in S-files is in km/h. If the code divides by 3.6 to get m/s for GPS,
# but CAN velocity is already in km/h and the code also divides by 3.6,
# then the CAN velocity label would be correct.
# BUT if the code does NOT divide GPS speed, or the V-file velocity column
# was actually in a different unit...

# Let's check if y_max * 3.6 matches any raw column max
print("Checking if y labels match raw GPS speed directly (no conversion)...")
s_m_path = DATASET_ROOT / manifest['trips']['M']['s_file']
s_m_df = pd.read_csv(s_m_path, encoding='latin-1')
s_m_df.columns = [c.strip() for c in s_m_df.columns]
gps_col_m = [c for c in s_m_df.columns if 'gps speed' in c.lower()][0]
gps_speed_m = pd.to_numeric(s_m_df[gps_col_m], errors='coerce')
print(f"  S-M GPS Speed (raw): min={gps_speed_m.min():.2f}, max={gps_speed_m.max():.2f}")

# Check V-M CAN velocity
v_m_path = DATASET_ROOT / manifest['trips']['M']['v_file']
v_m_df = pd.read_csv(v_m_path, encoding='latin-1')
v_m_df.columns = [c.strip() for c in v_m_df.columns]
print(f"  V-M columns: {list(v_m_df.columns)}")
for c in v_m_df.columns:
    if 'velocity' in c.lower():
        vals = pd.to_numeric(v_m_df[c], errors='coerce')
        print(f"    '{c}': min={vals.min():.2f}, max={vals.max():.2f}, mean={vals.mean():.2f}")

# Now check the largest trip contributor - S2
s_s2_path = DATASET_ROOT / manifest['trips']['S2']['s_file']
s_s2_df = pd.read_csv(s_s2_path, encoding='latin-1')
s_s2_df.columns = [c.strip() for c in s_s2_df.columns]
gps_col_s2 = [c for c in s_s2_df.columns if 'gps speed' in c.lower()][0]
gps_speed_s2 = pd.to_numeric(s_s2_df[gps_col_s2], errors='coerce')
print(f"  S-S2 GPS Speed (raw): min={gps_speed_s2.min():.2f}, max={gps_speed_s2.max():.2f}")

v_s2_path = DATASET_ROOT / manifest['trips']['S2']['v_file']
v_s2_df = pd.read_csv(v_s2_path, encoding='latin-1')
v_s2_df.columns = [c.strip() for c in v_s2_df.columns]
print(f"  V-S2 columns: {list(v_s2_df.columns)}")
for c in v_s2_df.columns:
    if 'velocity' in c.lower():
        vals = pd.to_numeric(v_s2_df[c], errors='coerce')
        print(f"    '{c}': min={vals.min():.2f}, max={vals.max():.2f}, mean={vals.mean():.2f}")

# Hypothesis B: V-file had wrong column selected (e.g. "Vertical Velocity" 
# instead of "Velocity (km/hr)")
# Already partially tested above by showing all velocity-named columns

# Hypothesis C: Timestamp non-monotonicity causing velocity spikes via finite differences
print("\nChecking S-M time monotonicity in detail...")
time_col_m = [c for c in s_m_df.columns if 'time since start' in c.lower()][0]
time_m = pd.to_numeric(s_m_df[time_col_m], errors='coerce')
diffs_m = time_m.diff()
neg_m = diffs_m[diffs_m < 0]
if len(neg_m) > 0:
    print(f"  S-M has {len(neg_m)} backward time jumps")
    for idx in neg_m.index[:5]:
        prev_t = time_m.iloc[idx-1]
        cur_t = time_m.iloc[idx]
        delta = cur_t - prev_t
        print(f"    Row {idx}: {prev_t:.1f} ms -> {cur_t:.1f} ms (delta = {delta:.1f} ms)")
        # Show what GPS speed was around this point
        if gps_col_m in s_m_df.columns:
            gs = pd.to_numeric(s_m_df[gps_col_m], errors='coerce')
            print(f"    GPS speed at row {idx-1}: {gs.iloc[idx-1]:.2f}, row {idx}: {gs.iloc[idx]:.2f}")

print("\n\nDONE — forensic analysis complete.")
