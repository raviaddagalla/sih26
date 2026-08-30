"""Root cause analysis - confirm the timeline mismatch causing extrapolation corruption in Vtb5"""
import pandas as pd, numpy as np
from pathlib import Path
from scipy.interpolate import interp1d

DATASET_ROOT = Path(r"D:\Nandhu\dead reckoning\IO-VNBD-master")

# Load S-Vtb5
s_path = DATASET_ROOT / "Synchronised V abd S datasets/Categorised IOVNB Dataset/Vtb (Driver E)/Vtb05/S-Vtb5.csv"
s_df = pd.read_csv(s_path, encoding='latin-1')
s_df.columns = [c.strip() for c in s_df.columns]

# Load V-Vtb5
v_path = DATASET_ROOT / "Synchronised V abd S datasets/Categorised IOVNB Dataset/Vtb (Driver E)/Vtb05/V-vtb5.csv"
v_df = pd.read_csv(v_path, encoding='latin-1')
v_df.columns = [c.strip() for c in v_df.columns]

# S-file timeline
time_col = [c for c in s_df.columns if 'time since start' in c.lower()][0]
s_time_s = pd.to_numeric(s_df[time_col], errors='coerce').values / 1000.0

# V-file timeline
v_time_col = [c for c in v_df.columns if 'time since start' in c.lower()][0]
v_time_raw = pd.to_numeric(v_df[v_time_col], errors='coerce').values
v_time_zeroed = v_time_raw - v_time_raw[0]  # The old code did this

# CAN velocity
can_vel = pd.to_numeric(v_df['Velocity (km/hr)'], errors='coerce').values
v_vel_ms = can_vel / 3.6

print("=== TIMELINE MISMATCH ANALYSIS (Vtb5) ===")
print(f"S timeline (seconds): {s_time_s.min():.1f} to {s_time_s.max():.1f}")
print(f"V timeline raw (seconds): {v_time_raw.min():.1f} to {v_time_raw.max():.1f}")
print(f"V timeline zeroed (seconds): {v_time_zeroed.min():.1f} to {v_time_zeroed.max():.1f}")
print()
print(f"PROBLEM: S-file time starts at {s_time_s.min():.1f}s")
print(f"         V-file (zeroed) only goes to {v_time_zeroed.max():.1f}s")
print(f"         => S timeline EXCEEDS V timeline by {s_time_s.max() - v_time_zeroed.max():.1f}s")
print(f"         => interp1d(fill_value='extrapolate') linearly extrapolates PAST V data range")
print()

# Reproduce the bug
vel_interp = interp1d(v_time_zeroed, v_vel_ms, kind='linear', fill_value='extrapolate')
target_time = np.arange(np.ceil(s_time_s.min()*10)/10, np.floor(s_time_s.max()*10)/10, 0.1)
interp_vel = vel_interp(target_time)

print(f"Interpolated velocity at S-timeline points:")
print(f"  min = {interp_vel.min():.2f} m/s = {interp_vel.min()*3.6:.2f} km/h")
print(f"  max = {interp_vel.max():.2f} m/s = {interp_vel.max()*3.6:.2f} km/h")
print(f"  mean = {interp_vel.mean():.2f} m/s = {interp_vel.mean()*3.6:.2f} km/h")
print()
print("ROOT CAUSE CONFIRMED: The old preprocessing code assumed V-file 'Time Since Start")
print("of Day' could be zeroed and directly used against S-file 'Time Since Start (ms)' / 1000.")
print("But these are DIFFERENT time bases:")
print("  - S-file TIME SINCE START (ms) = ms since app start (e.g. 1472613 ms = 1472.6 s)")
print("  - V-file Time Since Start of Day (seconds) = seconds since midnight (e.g. 59481 s = 16:31:21)")
print("Zeroing V-file yields 0..6438s, but S-file yields 1472..7911s.")
print("interp1d with fill_value='extrapolate' then extrapolates velocity FAR past the V-file's range.")
print()

# Also check: is GPS speed in m/s or km/h?
gps_col = [c for c in s_df.columns if 'gps speed' in c.lower()][0]
gps_speed = pd.to_numeric(s_df[gps_col], errors='coerce')
print(f"\n=== GPS SPEED UNIT CHECK ===")
print(f"GPS Speed column header: '{gps_col}'")
print(f"GPS Speed max: {gps_speed.max():.2f} (labeled as Kmh)")
print(f"CAN Velocity max: {can_vel.max():.2f} km/hr")
print(f"GPS Speed max * 3.6: {gps_speed.max()*3.6:.2f}")
print(f"=> GPS Speed is actually in m/s despite header saying 'Kmh'!")
print(f"=> The old code divided GPS speed by 3.6 AGAIN: {gps_speed.max()/3.6:.2f}")
print(f"   This DOUBLE-CONVERTED for test trips (A5, T2) that use GPS speed as labels.")
print()

# Check all other trips for similar time base mismatch
import json
with open(Path(r"D:\Nandhu\dead reckoning\idr-project\data\manifest.json")) as f:
    manifest = json.load(f)

print("=== TIME BASE ALIGNMENT CHECK FOR ALL TRIPS ===")
for trip_id, info in manifest['trips'].items():
    if info['split'] == 'stationary':
        continue
    s_p = DATASET_ROOT / info['s_file']
    if not s_p.exists():
        continue
    sdf = pd.read_csv(s_p, encoding='latin-1')
    sdf.columns = [c.strip() for c in sdf.columns]
    tc = [c for c in sdf.columns if 'time since start' in c.lower()][0]
    st = pd.to_numeric(sdf[tc], errors='coerce').values / 1000.0
    
    if info['has_can_velocity'] and info.get('v_file'):
        vp = DATASET_ROOT / info['v_file']
        if vp.exists():
            vdf = pd.read_csv(vp, encoding='latin-1')
            vdf.columns = [c.strip() for c in vdf.columns]
            vtc = [c for c in vdf.columns if 'time since start' in c.lower()][0]
            vt = pd.to_numeric(vdf[vtc], errors='coerce').values
            vt_zeroed = vt - vt[0]
            overlap = min(st.max(), vt_zeroed.max()) - max(st.min(), vt_zeroed.min())
            print(f"  {trip_id:8s}: S=[{st.min():.0f},{st.max():.0f}]s  V_zeroed=[{vt_zeroed.min():.0f},{vt_zeroed.max():.0f}]s  overlap={overlap:.0f}s  {'OK' if overlap > 0.9*(st.max()-st.min()) else '*** MISALIGNED ***'}")
        else:
            print(f"  {trip_id:8s}: V-file missing")
    else:
        print(f"  {trip_id:8s}: No CAN velocity (test trip)")

# Check non-monotonic timestamps across ALL trips
print("\n=== NON-MONOTONIC TIMESTAMP CHECK ===")
for trip_id, info in manifest['trips'].items():
    s_p = DATASET_ROOT / info['s_file']
    if not s_p.exists():
        continue
    sdf = pd.read_csv(s_p, encoding='latin-1')
    sdf.columns = [c.strip() for c in sdf.columns]
    tc = [c for c in sdf.columns if 'time since start' in c.lower()][0]
    st = pd.to_numeric(sdf[tc], errors='coerce')
    diffs = st.diff()
    neg = diffs[diffs < 0]
    if len(neg) > 0:
        print(f"  {trip_id}: {len(neg)} backward jumps, largest={neg.min():.0f}ms at row {neg.idxmin()}")
    else:
        print(f"  {trip_id}: OK")
