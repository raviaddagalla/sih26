"""
Phase 3: Map Matching
Hidden Markov Model (HMM) Viterbi map-matching or simple perpendicular snap-to-road.
"""
import numpy as np
from math import radians, cos, sin, asin, sqrt

def haversine(lon1, lat1, lon2, lat2):
    """
    Calculate the great circle distance between two points 
    on the earth (specified in decimal degrees).
    Returns distance in meters.
    """
    # convert decimal degrees to radians 
    lon1, lat1, lon2, lat2 = map(radians, [lon1, lat1, lon2, lat2])

    # haversine formula 
    dlon = lon2 - lon1 
    dlat = lat2 - lat1 
    a = sin(dlat/2)**2 + cos(lat1) * cos(lat2) * sin(dlon/2)**2
    c = 2 * asin(sqrt(a)) 
    r = 6371000 # Radius of earth in meters
    return c * r

def point_to_line_distance(pt, line_start, line_end):
    """
    Calculate the perpendicular distance from a point to a line segment.
    pt, line_start, line_end: (lon, lat) tuples
    Uses a fast Cartesian approximation valid for small distances.
    Returns: distance in meters, and the projected (lon, lat) point on the segment.
    """
    # Convert to approximate local Cartesian (meters)
    R = 6371000
    lat_rad = radians(pt[1])
    
    def to_xy(p):
        x = p[0] * (np.pi/180.0) * R * cos(lat_rad)
        y = p[1] * (np.pi/180.0) * R
        return np.array([x, y])
        
    def to_lonlat(xy):
        lon = xy[0] / (R * cos(lat_rad) * (np.pi/180.0))
        lat = xy[1] / (R * (np.pi/180.0))
        return (lon, lat)

    p = to_xy(pt)
    v = to_xy(line_start)
    w = to_xy(line_end)
    
    l2 = np.sum((w - v)**2)
    if l2 == 0:
        return haversine(pt[0], pt[1], line_start[0], line_start[1]), line_start
        
    # Consider the line extending the segment, parameterized as v + t (w - v).
    # We find projection of point p onto the line. 
    # It falls where t = [(p-v) . (w-v)] / |w-v|^2
    t = np.dot(p - v, w - v) / l2
    
    if t < 0.0:
        proj = v
        proj_lonlat = line_start
    elif t > 1.0:
        proj = w
        proj_lonlat = line_end
    else:
        proj = v + t * (w - v)
        proj_lonlat = to_lonlat(proj)
        
    dist = np.linalg.norm(p - proj)
    return dist, proj_lonlat

class SimpleMapMatcher:
    """
    A basic map matcher that snaps points to the nearest road segment.
    In a full production system, this would be an HMM tracking multiple hypotheses.
    """
    def __init__(self, road_segments):
        """
        road_segments: List of ((lon1, lat1), (lon2, lat2)) tuples representing road geometry.
        """
        self.segments = road_segments
        
    def snap(self, lat, lon):
        """
        Snap a coordinate to the nearest road segment.
        Returns: (snapped_lat, snapped_lon)
        """
        if not self.segments:
            return lat, lon
            
        min_dist = float('inf')
        best_proj = (lon, lat)
        
        pt = (lon, lat)
        
        for segment in self.segments:
            start, end = segment
            dist, proj = point_to_line_distance(pt, start, end)
            
            if dist < min_dist:
                min_dist = dist
                best_proj = proj
                
        # Return lat, lon (proj is lon, lat)
        return best_proj[1], best_proj[0]
\n
class HMMMapMatcher:
    def __init__(self, road_segments, emission_sigma=10.0, trans_beta=20.0):
        self.segments = road_segments
        self.emission_sigma = emission_sigma
        self.trans_beta = trans_beta
        
    def match(self, trajectory):
        '''
        Viterbi map matching.
        trajectory: list of (lat, lon)
        Returns: list of snapped (lat, lon)
        '''
        if not self.segments or not trajectory:
            return trajectory
            
        # Initialize Viterbi structures
        V = [{}]
        path = {}
        
        # Emission probability based on distance
        def emission_prob(dist):
            return (1.0 / (np.sqrt(2 * np.pi) * self.emission_sigma)) * np.exp(-0.5 * (dist / self.emission_sigma)**2)
            
        # Transition probability based on route distance vs great circle distance
        def trans_prob(p1, p2, p1_proj, p2_proj):
            # p1, p2 are raw trajectory points
            # p1_proj, p2_proj are projected points on the segment
            gc_dist = haversine(p1[1], p1[0], p2[1], p2[0])
            route_dist = haversine(p1_proj[1], p1_proj[0], p2_proj[1], p2_proj[0])
            diff = abs(gc_dist - route_dist)
            return (1.0 / self.trans_beta) * np.exp(-diff / self.trans_beta)

        # Pre-compute projections for all segments for the first point
        pt0 = (trajectory[0][1], trajectory[0][0]) # (lon, lat)
        for i, segment in enumerate(self.segments):
            dist, proj = point_to_line_distance(pt0, segment[0], segment[1])
            # Only consider segments within a reasonable threshold (e.g. 50 meters)
            if dist > 100.0:
                continue
            V[0][i] = np.log(emission_prob(dist) + 1e-12)
            path[i] = [(proj[1], proj[0])] # lat, lon
            
        if not V[0]:
            # fallback if nothing is close
            min_dist = float('inf')
            best_i, best_proj = 0, pt0
            for i, segment in enumerate(self.segments):
                dist, proj = point_to_line_distance(pt0, segment[0], segment[1])
                if dist < min_dist:
                    min_dist, best_i, best_proj = dist, i, proj
            V[0][best_i] = 0.0
            path[best_i] = [(best_proj[1], best_proj[0])]

        # Run Viterbi
        for t in range(1, len(trajectory)):
            V.append({})
            newpath = {}
            pt = (trajectory[t][1], trajectory[t][0]) # (lon, lat)
            prev_pt = (trajectory[t-1][1], trajectory[t-1][0])
            
            # Find candidate segments for current point
            candidates = []
            for i, segment in enumerate(self.segments):
                dist, proj = point_to_line_distance(pt, segment[0], segment[1])
                if dist < 100.0:
                    candidates.append((i, dist, proj))
                    
            if not candidates:
                min_dist = float('inf')
                best_i, best_proj = 0, pt
                for i, segment in enumerate(self.segments):
                    dist, proj = point_to_line_distance(pt, segment[0], segment[1])
                    if dist < min_dist:
                        min_dist, best_i, best_proj = dist, i, proj
                candidates.append((best_i, min_dist, best_proj))

            for y, dist, proj in candidates:
                prob, state = max(
                    (V[t-1][y0] + np.log(trans_prob(prev_pt, pt, path[y0][-1][::-1], proj) + 1e-12) + np.log(emission_prob(dist) + 1e-12), y0)
                    for y0 in V[t-1]
                )
                V[t][y] = prob
                newpath[y] = path[state] + [(proj[1], proj[0])]
            
            path = newpath

        n = len(trajectory) - 1
        prob, state = max((V[n][y], y) for y in V[n])
        return path[state]
