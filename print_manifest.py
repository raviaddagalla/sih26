import json, os
base = r'D:\Nandhu\dead reckoning\idr-project'
with open(os.path.join(base, 'data/manifest.json')) as f:
    manifest = json.load(f)
for trip_id, info in manifest['trips'].items():
    if info['split'] == 'test':
        print(f'{trip_id}: road_types={info["road_types"]}')