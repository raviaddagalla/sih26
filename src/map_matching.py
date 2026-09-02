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
        if self.segments:
            from scipy.spatial import cKDTree
            # Extract midpoints for fast spatial indexing
            midpoints = []
            for segment in self.segments:
                s = segment['start'] if isinstance(segment, dict) else segment[0]
                e = segment['end'] if isinstance(segment, dict) else segment[1]
                # s and e are [lat, lon], we want [lon, lat] for the midpoint index
                lon_mid = (s[1] + e[1]) / 2.0
                lat_mid = (s[0] + e[0]) / 2.0
                midpoints.append([lon_mid, lat_mid])
            self.tree = cKDTree(midpoints)
        else:
            self.tree = None
        
    def snap(self, lat, lon, max_snap_distance_m=50.0):
        """
        Snap a coordinate to the nearest road segment.
        Returns: (snapped_lat, snapped_lon)
        """
        if not self.segments or self.tree is None:
            return lat, lon
            
        pt = (lon, lat)
        
        # Query KDTree for nearest 20 segments
        k = min(20, len(self.segments))
        _, idxs = self.tree.query([lon, lat], k=k)
        if isinstance(idxs, (int, np.integer)):
            idxs = [idxs]
            
        min_dist = float('inf')
        best_proj = (lon, lat)
        
        for idx in idxs:
            segment = self.segments[idx]
            s = segment['start'] if isinstance(segment, dict) else segment[0]
            e = segment['end'] if isinstance(segment, dict) else segment[1]
            start = (s[1], s[0])
            end = (e[1], e[0])
            dist, proj = point_to_line_distance(pt, start, end)
            
            if dist < min_dist:
                min_dist = dist
                best_proj = proj
                
        if min_dist > max_snap_distance_m:
            return lat, lon
            
        return best_proj[1], best_proj[0]

    def snap_with_meta(self, lat, lon, max_snap_distance_m=50.0):
        """
        Snap a coordinate to the nearest road segment and return its metadata.
        Returns: (snapped_lat, snapped_lon, metadata_dict)
        """
        if not self.segments or self.tree is None:
            return lat, lon, {}
            
        pt = (lon, lat)
        k = min(20, len(self.segments))
        _, idxs = self.tree.query([lon, lat], k=k)
        if isinstance(idxs, (int, np.integer)):
            idxs = [idxs]
            
        min_dist = float('inf')
        best_proj = (lon, lat)
        best_meta = {}
        
        for idx in idxs:
            segment = self.segments[idx]
            s = segment['start'] if isinstance(segment, dict) else segment[0]
            e = segment['end'] if isinstance(segment, dict) else segment[1]
            start = (s[1], s[0])
            end = (e[1], e[0])
            dist, proj = point_to_line_distance(pt, start, end)
            
            if dist < min_dist:
                min_dist = dist
                best_proj = proj
                best_meta = segment if isinstance(segment, dict) else {}
                
        if min_dist > max_snap_distance_m:
            return lat, lon, {}
            
        return best_proj[1], best_proj[0], best_meta

class HMMMapMatcher:
    def __init__(self, road_segments, emission_sigma=10.0, trans_beta=20.0):
        self.segments = road_segments
        self.emission_sigma = emission_sigma
        self.trans_beta = trans_beta
        
        if self.segments:
            from scipy.spatial import cKDTree
            midpoints = []
            for segment in self.segments:
                s = segment['start'] if isinstance(segment, dict) else segment[0]
                e = segment['end'] if isinstance(segment, dict) else segment[1]
                lon_mid = (s[1] + e[1]) / 2.0
                lat_mid = (s[0] + e[0]) / 2.0
                midpoints.append([lon_mid, lat_mid])
            self.tree = cKDTree(midpoints)
        else:
            self.tree = None
        
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
        
        # Query KDTree for nearest 50 segments
        k = min(50, len(self.segments))
        _, idxs = self.tree.query([pt0[0], pt0[1]], k=k)
        if isinstance(idxs, (int, np.integer)):
            idxs = [idxs]
            
        for idx in idxs:
            segment = self.segments[idx]
            s = segment['start'] if isinstance(segment, dict) else segment[0]
            e = segment['end'] if isinstance(segment, dict) else segment[1]
            start = (s[1], s[0]) # (lon, lat)
            end = (e[1], e[0]) # (lon, lat)
            dist, proj = point_to_line_distance(pt0, start, end)
            # Only consider segments within a reasonable threshold (e.g. 500 meters)
            if dist > 500.0:
                continue
            V[0][idx] = np.log(emission_prob(dist) + 1e-12)
            path[idx] = [(proj[1], proj[0])] # lat, lon
            
        if not V[0]:
            # fallback if nothing is close
            min_dist = float('inf')
            best_idx, best_proj = 0, pt0
            for idx in idxs:
                segment = self.segments[idx]
                s = segment['start'] if isinstance(segment, dict) else segment[0]
                e = segment['end'] if isinstance(segment, dict) else segment[1]
                start = (s[1], s[0])
                end = (e[1], e[0])
                dist, proj = point_to_line_distance(pt0, start, end)
                if dist < min_dist:
                    min_dist, best_idx, best_proj = dist, idx, proj
            V[0][best_idx] = 0.0
            path[best_idx] = [(best_proj[1], best_proj[0])]

        # Run Viterbi
        for t in range(1, len(trajectory)):
            V.append({})
            newpath = {}
            pt = (trajectory[t][1], trajectory[t][0]) # (lon, lat)
            prev_pt = (trajectory[t-1][1], trajectory[t-1][0])
            
            # Find candidate segments for current point
            candidates = []
            _, idxs = self.tree.query([pt[0], pt[1]], k=k)
            if isinstance(idxs, (int, np.integer)):
                idxs = [idxs]
                
            for idx in idxs:
                segment = self.segments[idx]
                s = segment['start'] if isinstance(segment, dict) else segment[0]
                e = segment['end'] if isinstance(segment, dict) else segment[1]
                start = (s[1], s[0])
                end = (e[1], e[0])
                dist, proj = point_to_line_distance(pt, start, end)
                if dist < 500.0:
                    candidates.append((idx, dist, proj))
                    
            if not candidates:
                min_dist = float('inf')
                best_idx, best_proj = 0, pt
                for idx in idxs:
                    segment = self.segments[idx]
                    s = segment['start'] if isinstance(segment, dict) else segment[0]
                    e = segment['end'] if isinstance(segment, dict) else segment[1]
                    start = (s[1], s[0])
                    end = (e[1], e[0])
                    dist, proj = point_to_line_distance(pt, start, end)
                    if dist < min_dist:
                        min_dist, best_idx, best_proj = dist, idx, proj
                candidates.append((best_idx, min_dist, best_proj))

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

class RBPFMapMatcher:
    """
    Rao-Blackwellized Particle Filter (RBPF) for map matching.
    Uses building footprints as hard constraints (zero weight if inside).
    Uses road segments as soft constraints.
    """
    def __init__(self, road_segments, buildings=None):
        self.segments = road_segments
        self.buildings = buildings or []
        
        self.building_paths = []
        if self.buildings:
            from matplotlib.path import Path as MplPath
            for b in self.buildings:
                if len(b['polygon']) > 2:
                    self.building_paths.append(MplPath(b['polygon']))
                    
        # Simple spatial index for segments
        if self.segments:
            from scipy.spatial import cKDTree
            midpoints = []
            for segment in self.segments:
                s = segment['start'] if isinstance(segment, dict) else segment[0]
                e = segment['end'] if isinstance(segment, dict) else segment[1]
                midpoints.append([(s[1] + e[1])/2.0, (s[0] + e[0])/2.0])
            self.tree = cKDTree(midpoints)
        else:
            self.tree = None

    def in_building(self, lat, lon):
        if not self.building_paths:
            return False
        pt = [lat, lon]
        for path in self.building_paths:
            if path.contains_point(pt):
                return True
        return False

    def distance_to_road(self, lat, lon):
        if not self.tree:
            return 0.0
        pt = (lon, lat)
        _, idxs = self.tree.query([lon, lat], k=10)
        if isinstance(idxs, (int, np.integer)):
            idxs = [idxs]
            
        min_dist = float('inf')
        for idx in idxs:
            segment = self.segments[idx]
            s = segment['start'] if isinstance(segment, dict) else segment[0]
            e = segment['end'] if isinstance(segment, dict) else segment[1]
            start = (s[1], s[0])
            end = (e[1], e[0])
            dist, _ = point_to_line_distance(pt, start, end)
            if dist < min_dist:
                min_dist = dist
        return min_dist

    def match(self, trajectory):
        """
        Runs the RBPF over a trajectory.
        trajectory: list of (lat, lon)
        Returns filtered trajectory.
        """
        if not trajectory:
            return trajectory
            
        num_particles = 1000
        # Initialize particles around the first point
        # [lat, lon, weight]
        lat0, lon0 = trajectory[0]
        
        # Add slight noise to initial position
        particles = np.zeros((num_particles, 3))
        particles[:, 0] = lat0 + np.random.randn(num_particles) * 1e-5
        particles[:, 1] = lon0 + np.random.randn(num_particles) * 1e-5
        particles[:, 2] = 1.0 / num_particles
        
        filtered_traj = []
        
        for t in range(len(trajectory)):
            if t > 0:
                # Predict step: move particles by the observed delta in trajectory
                dlat = trajectory[t][0] - trajectory[t-1][0]
                dlon = trajectory[t][1] - trajectory[t-1][1]
                
                # Add process noise
                particles[:, 0] += dlat + np.random.randn(num_particles) * 2e-6
                particles[:, 1] += dlon + np.random.randn(num_particles) * 2e-6
            
            # Update step: apply constraints
            for i in range(num_particles):
                p_lat, p_lon = particles[i, 0], particles[i, 1]
                
                # Hard constraint: Buildings
                if self.in_building(p_lat, p_lon):
                    particles[i, 2] = 0.0
                    continue
                    
                # Soft constraint: Road distance
                d_road = self.distance_to_road(p_lat, p_lon)
                # Weight formula from paper: w(d) = 1 / log(max(d_min, d))
                d_min = 2.5
                weight = 1.0 / max(0.1, np.log(max(d_min, d_road)))
                particles[i, 2] *= weight
                
            # Normalize
            weight_sum = np.sum(particles[:, 2])
            if weight_sum > 0:
                particles[:, 2] /= weight_sum
            else:
                # All particles died (e.g. all in buildings), reset weights
                particles[:, 2] = 1.0 / num_particles
                
            # Resample if effective particles < threshold
            n_eff = 1.0 / (np.sum(particles[:, 2]**2) + 1e-12)
            if n_eff < num_particles / 2.0:
                indices = np.random.choice(num_particles, size=num_particles, p=particles[:, 2])
                particles = particles[indices]
                particles[:, 2] = 1.0 / num_particles
                
            # Estimate current position (weighted mean)
            est_lat = np.average(particles[:, 0], weights=particles[:, 2])
            est_lon = np.average(particles[:, 1], weights=particles[:, 2])
            filtered_traj.append((est_lat, est_lon))
            
        return filtered_traj
