import json
import urllib.request
import urllib.parse
from pathlib import Path
import numpy as np

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
WEBAPP_PUBLIC_DIR = PROJECT_ROOT / "webapp" / "public"

def main():
    print("Loading sample trip to determine bounding box...")
    with open(WEBAPP_PUBLIC_DIR / "model" / "sample_trip.json", "r") as f:
        data = json.load(f)
        
    initial_lat, initial_lon = data["initial_coords"]
    
    # Let's create a bounding box of roughly 1km around the start point
    # 1 degree of latitude is ~111km. 1km is ~0.009 degrees.
    margin = 0.015
    south = initial_lat - margin
    north = initial_lat + margin
    west = initial_lon - margin
    east = initial_lon + margin
    
    bbox = f"{south},{west},{north},{east}"
    print(f"Bounding box: {bbox}")
    
    overpass_query = f"""
    [out:json];
    (
      way["highway"]({bbox});
    );
    out geom;
    """
    
    url = "https://overpass-api.de/api/interpreter"
    data_payload = urllib.parse.urlencode({'data': overpass_query}).encode('utf-8')
    
    print("Querying Overpass API...")
    headers = {
        'User-Agent': 'IDR-Demo/1.0',
        'Accept': 'application/json'
    }
    req = urllib.request.Request(url, data=data_payload, headers=headers)
    with urllib.request.urlopen(req) as response:
        result = json.loads(response.read().decode('utf-8'))
        
    print(f"Fetched {len(result.get('elements', []))} elements.")
    
    # We want to format this into a list of line segments: [ [lat1, lon1], [lat2, lon2] ]
    # to match what mapMatching.js expects.
    
    segments = []
    for element in result.get('elements', []):
        if element['type'] == 'way' and 'geometry' in element:
            nodes = element['geometry']
            for i in range(len(nodes) - 1):
                p1 = [nodes[i]['lat'], nodes[i]['lon']]
                p2 = [nodes[i+1]['lat'], nodes[i+1]['lon']]
                segments.append([p1, p2])
                
    print(f"Extracted {len(segments)} road segments.")
    
    out_path = WEBAPP_PUBLIC_DIR / "road_network.json"
    with open(out_path, "w") as f:
        json.dump(segments, f)
        
    print(f"Saved to {out_path}")

if __name__ == "__main__":
    main()
