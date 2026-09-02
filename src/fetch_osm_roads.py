import json
import urllib.request
import urllib.parse
from pathlib import Path
import numpy as np
import sys
import argparse

import dataset
import common

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
WEBAPP_PUBLIC_DIR = PROJECT_ROOT / "webapp" / "public"
DATA_PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
DATA_PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

def fetch_road_network(trip_id=None, margin=0.015):
    if trip_id is None:
        print("Loading sample trip to determine bounding box...")
        with open(WEBAPP_PUBLIC_DIR / "model" / "sample_trip.json", "r") as f:
            data = json.load(f)
        initial_lat, initial_lon = data["initial_coords"]
        south = initial_lat - margin
        north = initial_lat + margin
        west = initial_lon - margin
        east = initial_lon + margin
    else:
        print(f"Loading trip {trip_id} from dataset...")
        df = dataset.load_synced_trip(trip_id)
        if df is None or len(df) == 0:
            print(f"Failed to load trip {trip_id}.")
            return []
            
        min_lat, max_lat = df['ref_lat'].min(), df['ref_lat'].max()
        min_lon, max_lon = df['ref_lon'].min(), df['ref_lon'].max()
        south = min_lat - margin
        north = max_lat + margin
        west = min_lon - margin
        east = max_lon + margin

    bbox = f"{south},{west},{north},{east}"
    print(f"Bounding box: {bbox}")
    
    overpass_query = f"""
    [out:json][timeout:300];
    (
      way["highway"~"motorway|trunk|primary|secondary|tertiary|unclassified|residential"]({bbox});
      way["building"]({bbox});
    );
    out body geom;
    """
    
    url = "https://overpass-api.de/api/interpreter"
    data_payload = urllib.parse.urlencode({'data': overpass_query}).encode('utf-8')
    
    print("Querying Overpass API...")
    headers = {
        'User-Agent': 'IDR-Demo/1.0',
        'Accept': 'application/json'
    }
    req = urllib.request.Request(url, data=data_payload, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.loads(response.read().decode('utf-8'))
    except Exception as e:
        print(f"Failed to fetch road network from Overpass API: {e}")
        return []
        
    print(f"Fetched {len(result.get('elements', []))} elements.")
    
    segments = []
    buildings = []
    for element in result.get('elements', []):
        if element['type'] == 'way' and 'geometry' in element:
            tags = element.get('tags', {})
            highway_type = tags.get('highway', None)
            is_building = tags.get('building', None)
            
            nodes = element['geometry']
            
            if highway_type:
                for i in range(len(nodes) - 1):
                    p1 = [nodes[i]['lat'], nodes[i]['lon']]
                    p2 = [nodes[i+1]['lat'], nodes[i+1]['lon']]
                    segments.append({
                        "start": p1,
                        "end": p2,
                        "highway": highway_type,
                        "maxspeed": tags.get('maxspeed', None)
                    })
            elif is_building:
                polygon = [[n['lat'], n['lon']] for n in nodes]
                buildings.append({
                    "polygon": polygon,
                    "name": tags.get('name', 'Unknown')
                })
                
    print(f"Extracted {len(segments)} road segments and {len(buildings)} buildings.")
    
    if trip_id:
        out_path = DATA_PROCESSED_DIR / f"road_network_{trip_id}.json"
    else:
        out_path = WEBAPP_PUBLIC_DIR / "road_network.json"
        
    output_data = {
        "segments": segments,
        "buildings": buildings
    }
        
    with open(out_path, "w") as f:
        json.dump(output_data, f)
        
    print(f"Saved to {out_path}")
    return output_data

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trip_id", type=str, default=None, help="Trip ID to fetch road network for")
    parser.add_argument("--margin", type=float, default=0.015, help="Bounding box margin in degrees")
    args = parser.parse_args()
    
    fetch_road_network(args.trip_id, args.margin)

if __name__ == "__main__":
    main()
