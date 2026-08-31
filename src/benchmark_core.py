import numpy as np
from ekf import EKF

def haversine(lat1, lon1, lat2, lon2):
    R = 6378137.0
    lat1, lon1, lat2, lon2 = map(np.radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = np.sin(dlat/2.0)**2 + np.cos(lat1) * np.cos(lat2) * np.sin(dlon/2.0)**2
    c = 2 * np.arcsin(np.sqrt(a))
    return R * c

def evaluate_blackout_window(
    pred_velocity: np.ndarray,      
    gyro_yaw_rate: np.ndarray,      
    gt_lat: np.ndarray,             
    gt_lon: np.ndarray,             
    gt_heading_deg: np.ndarray,     
    start_idx: int,
    duration_steps: int,
    dt_seconds: float,              
    min_reference_distance_m: float = 300.0,
) -> dict | None:
    """
    Evaluates a GNSS-denied window rigorously.
    Returns None if reference distance < min_reference_distance_m.
    """
    
    # 1. Compute path distance by summing haversine segments
    ref_dist_m = 0.0
    for i in range(duration_steps - 1):
        ref_dist_m += haversine(gt_lat[i], gt_lon[i], gt_lat[i+1], gt_lon[i+1])
        
    if ref_dist_m < min_reference_distance_m:
        return None
        
    # Is it a low motion window? E.g. speed < 2 m/s average
    expected_avg_speed = ref_dist_m / (duration_steps * dt_seconds)
    is_low_motion = bool(expected_avg_speed < 2.0)
    
    # Initialization
    init_lat, init_lon = gt_lat[0], gt_lon[0]
    init_heading_rad = np.radians(gt_heading_deg[0])
    if np.isnan(init_heading_rad):
        init_heading_rad = 0.0
        
    # EKF Setup
    ekf = EKF(init_lat, init_lon, init_heading_rad, pred_velocity[0])
    
    # Open Loop Setup
    ol_x, ol_y = 0.0, 0.0
    ol_theta = init_heading_rad
    
    # Step through window
    for i in range(duration_steps):
        v = pred_velocity[i]
        omega = gyro_yaw_rate[i]
        
        # EKF
        ekf.predict(dt_seconds, v, omega)
        
        # Open Loop (Euler)
        ol_x += v * np.sin(ol_theta) * dt_seconds
        ol_y += v * np.cos(ol_theta) * dt_seconds
        ol_theta += omega * dt_seconds
        
    ekf_lat, ekf_lon = ekf.get_latlon()
    ol_lat, ol_lon = ekf.xy_to_latlon(ol_x, ol_y)
    
    final_gt_lat = gt_lat[-1]
    final_gt_lon = gt_lon[-1]
    
    # Compute Final Errors
    ekf_final_error_m = haversine(final_gt_lat, final_gt_lon, ekf_lat, ekf_lon)
    open_loop_final_error_m = haversine(final_gt_lat, final_gt_lon, ol_lat, ol_lon)
    
    # Compute Drift % (No division by zero possible due to min_reference_distance_m gate)
    ekf_drift_pct = (ekf_final_error_m / ref_dist_m) * 100.0
    open_loop_drift_pct = (open_loop_final_error_m / ref_dist_m) * 100.0
    
    return {
        "reference_distance_m": float(ref_dist_m),
        "open_loop_final_error_m": float(open_loop_final_error_m),
        "ekf_final_error_m": float(ekf_final_error_m),
        "open_loop_drift_pct": float(open_loop_drift_pct),
        "ekf_drift_pct": float(ekf_drift_pct),
        "is_low_motion": is_low_motion,
        "start_idx": start_idx,
        "duration_steps": duration_steps,
        "dt_seconds": dt_seconds
    }
