"""
Download PVS trips 3-9 by constructing known file paths directly.
The file structure is consistent across all trips:
  PVS N/dataset_gps.csv
  PVS N/dataset_gps_mpu_left.csv
  PVS N/dataset_gps_mpu_right.csv
  PVS N/dataset_labels.csv
  PVS N/dataset_mpu_left.csv
  PVS N/dataset_mpu_right.csv
  PVS N/dataset_settings_left.csv
  PVS N/dataset_settings_right.csv
"""
import kaggle
import zipfile
import time
from pathlib import Path

DATASET = "jefmenegazzo/pvs-passive-vehicular-sensors-datasets"
OUTPUT_ROOT = Path(__file__).parent.parent / "data" / "raw" / "pvs"
OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)

kaggle.api.authenticate()

# These are the CSV files in each PVS trip folder (no videos)
CSV_FILES = [
    "dataset_gps.csv",
    "dataset_gps_mpu_left.csv",
    "dataset_gps_mpu_right.csv",
    "dataset_labels.csv",
    "dataset_mpu_left.csv",
    "dataset_mpu_right.csv",
    "dataset_settings_left.csv",
    "dataset_settings_right.csv",
]

TRIPS_TO_DOWNLOAD = range(3, 10)  # PVS 3 through PVS 9

total_bytes = 0
downloaded = 0
skipped = 0
failed = []

def try_download(kaggle_path, local_path):
    try:
        kaggle.api.dataset_download_file(
            DATASET, file_name=kaggle_path, path=local_path.parent, force=True, quiet=False
        )
        zip_candidate = local_path.parent / (local_path.name + ".zip")
        if zip_candidate.exists():
            print(f"    Extracting zip...")
            with zipfile.ZipFile(zip_candidate, 'r') as z:
                z.extractall(local_path.parent)
            zip_candidate.unlink()
        if local_path.exists() and local_path.stat().st_size > 0:
            return local_path.stat().st_size
        return 0
    except Exception as e:
        print(f"    Exception: {e}")
        return 0

for trip_num in TRIPS_TO_DOWNLOAD:
    folder_name = f"PVS {trip_num}"
    local_trip_dir = OUTPUT_ROOT / folder_name
    local_trip_dir.mkdir(parents=True, exist_ok=True)
    print(f"\n{'='*60}")
    print(f"Downloading {folder_name}...")
    print(f"{'='*60}")

    for csv_name in CSV_FILES:
        kaggle_path = f"{folder_name}/{csv_name}"
        local_path = local_trip_dir / csv_name

        if local_path.exists() and local_path.stat().st_size > 0:
            sz = local_path.stat().st_size
            print(f"  SKIP (exists {sz:,} bytes): {csv_name}")
            skipped += 1
            total_bytes += sz
            continue

        print(f"  Downloading: {kaggle_path}")
        sz = try_download(kaggle_path, local_path)

        if sz == 0:
            print(f"  -> FAILED first attempt. Retrying in 3s...")
            time.sleep(3)
            sz = try_download(kaggle_path, local_path)

        if sz > 0:
            print(f"  -> OK ({sz:,} bytes)")
            downloaded += 1
            total_bytes += sz
        else:
            print(f"  -> FAILED: {kaggle_path}")
            failed.append(kaggle_path)

print()
print("=" * 60)
print("SUMMARY")
print("=" * 60)
print(f"  Downloaded:  {downloaded}")
print(f"  Skipped:     {skipped}")
print(f"  Failed:      {len(failed)}")
print(f"  Total bytes: {total_bytes:,}")
if failed:
    print("\n  FAILED:")
    for f in failed:
        print(f"    - {f}")

print()
print("Local PVS directory:")
for folder in sorted(OUTPUT_ROOT.iterdir()):
    if folder.is_dir():
        csvs = list(folder.glob("*.csv"))
        print(f"  {folder.name}/  -> {len(csvs)} CSV files")
