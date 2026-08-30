"""
Phase 3: Calibration
Align smartphone orientation with the vehicle frame.
1. Gravity vector alignment at rest (determines pitch/roll).
2. Heading correlation during motion (aligns yaw to GPS course).
"""
import numpy as np
from scipy.spatial.transform import Rotation

def estimate_stationary_gravity(accel_data, threshold=0.1):
    """
    Estimate the gravity vector during a stationary period.
    accel_data: (N, 3) array of raw accelerometer data (m/s^2)
    Returns normalized gravity vector (3,).
    """
    # Assuming variance < threshold means stationary
    vars = np.var(accel_data, axis=0)
    if np.any(vars > threshold):
        print("Warning: Data may not be perfectly stationary.")
        
    g_vec = np.mean(accel_data, axis=0)
    g_norm = np.linalg.norm(g_vec)
    return g_vec / g_norm

def align_to_gravity(g_vec):
    """
    Compute rotation matrix to align the phone's Z-axis with gravity.
    g_vec: normalized gravity vector in phone frame.
    Returns: Rotation object that rotates phone frame to gravity-aligned frame.
    """
    target_z = np.array([0, 0, 1.0])
    
    # Axis of rotation
    v = np.cross(g_vec, target_z)
    s = np.linalg.norm(v)
    c = np.dot(g_vec, target_z)
    
    if s < 1e-6:
        # Already aligned (or opposite)
        if c > 0:
            return Rotation.identity()
        else:
            return Rotation.from_euler('x', np.pi)
            
    # Skew-symmetric matrix
    vx = np.array([
        [0, -v[2], v[1]],
        [v[2], 0, -v[0]],
        [-v[1], v[0], 0]
    ])
    
    R = np.eye(3) + vx + (vx @ vx) * ((1 - c) / (s**2))
    return Rotation.from_matrix(R)

def estimate_yaw_offset(gps_headings, integrated_yaws, min_speed=5.0):
    """
    Estimate the yaw offset between phone frame and vehicle frame.
    Requires motion (e.g. speed > 5 m/s) so GPS heading is reliable.
    gps_headings: (N,) array of GPS headings (degrees)
    integrated_yaws: (N,) array of phone yaws (degrees) from gyro integration
    speeds: (N,) array of GPS speeds (m/s)
    """
    # Difference between GPS heading and phone yaw
    diffs = gps_headings - integrated_yaws
    
    # Wrap to [-180, 180]
    diffs = (diffs + 180) % 360 - 180
    
    # Return median offset to be robust to outliers
    return np.median(diffs)

def calibrate_phone_mount(stationary_accel, moving_gps_heading, moving_phone_yaw):
    """
    Full calibration pipeline.
    """
    # 1. Pitch/Roll from gravity
    g_vec = estimate_stationary_gravity(stationary_accel)
    rot_gravity = align_to_gravity(g_vec)
    
    # 2. Yaw offset from motion
    yaw_offset = estimate_yaw_offset(moving_gps_heading, moving_phone_yaw)
    rot_yaw = Rotation.from_euler('z', yaw_offset, degrees=True)
    
    # Combined rotation: first align Z, then align yaw
    rot_combined = rot_yaw * rot_gravity
    return rot_combined
