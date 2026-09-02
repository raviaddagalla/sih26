import sys
import numpy as np
import pandas as pd
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent))
import preprocess
import common

def window_trip_seq(df, trip_id, seq_len=3000):
    """
    Slice the dataframe into non-overlapping contiguous sequences of `seq_len` (5 minutes at 10Hz).
    """
    feature_cols = [
        'Linear Accel X', 'Linear Accel Y', 'Linear Accel Z',
        'Gravity X', 'Gravity Y', 'Gravity Z',
        'Gyroscope Yaw', 'Gyroscope Pitch', 'Gyroscope Roll',
        'Orientation Yaw', 'Orientation Pitch', 'Orientation Roll'
    ]

    data = df[feature_cols].values
    velocities = df['Velocity_ms'].values

    X, y, ids = [], [], []
    # Use step=seq_len for non-overlapping contiguous chunks
    for i in range(0, len(data) - seq_len + 1, seq_len):
        window_x = data[i:i + seq_len]
        window_y = velocities[i:i + seq_len]
        
        if np.isnan(window_x).any() or np.isnan(window_y).any():
            continue

        X.append(window_x)
        y.append(window_y)
        ids.append(trip_id)

    return np.array(X), np.array(y), np.array(ids)


def process_seq():
    splits = {s: {'X': [], 'y': [], 'trip_id': []} for s in ['train', 'val', 'test']}

    print("=" * 70)
    print("PREPROCESSING SEQUENCES (Stateful Recurrent Integration)")
    print("=" * 70)

    # Build full trip list from SPLIT_TRIPS (includes all PVS trips) + manifest (IO-VNBD)
    all_trips = {}  # trip_id -> split
    for split_name, trip_ids in common.SPLIT_TRIPS.items():
        for tid in trip_ids:
            all_trips[tid] = split_name
    # Also include stationary-excluded IO-VNBD trips from manifest
    for trip_id, info in preprocess.manifest['trips'].items():
        if info['split'] == 'stationary':
            continue
        if trip_id not in all_trips:
            all_trips[trip_id] = info['split']

    for trip_id, split in all_trips.items():
        print(f"  Processing {trip_id} (split={split})...")

        if trip_id.startswith("PVS_"):
            sync_path = common.PROCESSED_DIR / f"sync_{trip_id}.csv"
            if not sync_path.exists():
                print(f"    WARNING: {sync_path} not found, skipping.")
                continue
            sync_df = pd.read_csv(sync_path)
        else:
            info = preprocess.manifest['trips'].get(trip_id)
            if info is None:
                print(f"    WARNING: {trip_id} not in manifest, skipping.")
                continue
            s_path = common.DATASET_ROOT / info['s_file']
            s_df = preprocess.load_s_file(s_path, trip_id)
            
            v_df = None
            if info['has_can_velocity'] and info.get('v_file'):
                v_path = common.DATASET_ROOT / info['v_file']
                v_df = preprocess.load_v_file(v_path, trip_id)

            s_df = preprocess.gravity_compensate(s_df)
            sync_df = preprocess.synchronize(s_df, v_df, info['has_can_velocity'], trip_id)
            sync_df = sync_df.dropna(subset=['Velocity_ms']).reset_index(drop=True)

        X, y, ids = window_trip_seq(sync_df, trip_id, seq_len=3000)

        if len(X) > 0:
            splits[split]['X'].append(X)
            splits[split]['y'].append(y)
            splits[split]['trip_id'].append(ids)

    # Flatten and save
    out_dict = {}
    for s in ['train', 'val', 'test']:
        if splits[s]['X']:
            X_all = np.concatenate(splits[s]['X'], axis=0)
            y_all = np.concatenate(splits[s]['y'], axis=0)
            ids_all = np.concatenate(splits[s]['trip_id'], axis=0)
        else:
            X_all = np.empty((0, 600, 12))
            y_all = np.empty((0, 600))
            ids_all = np.empty((0,))

        out_dict[f'X_{s}'] = X_all
        out_dict[f'y_{s}'] = y_all
        out_dict[f'trip_{s}'] = ids_all
        print(f"Split {s}: {len(X_all)} sequences of 5 min")

    out_path = common.PROCESSED_DIR / "dataset_seq.npz"
    np.savez_compressed(out_path, **out_dict)
    print(f"\nSaved sequence dataset to {out_path}")

if __name__ == "__main__":
    process_seq()
