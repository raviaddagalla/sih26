"""
Phase 3: Dead Reckoning
Integrator with Non-Holonomic Constraints (NHC).
"""
import numpy as np

class DeadReckoningIntegrator:
    """
    Integrates heading from yaw rate and position from forward velocity.
    Applies Non-Holonomic Constraint (NHC): lateral and vertical velocity are zero.
    """
    def __init__(self, initial_lat, initial_lon, initial_heading_rad):
        self.lat = initial_lat
        self.lon = initial_lon
        self.heading_rad = initial_heading_rad
        
        # Earth radius in meters
        self.R = 6378137.0
        
        self.trajectory = [(self.lat, self.lon)]
        
    def step(self, forward_velocity_ms, yaw_rate_rads, dt):
        """
        Update state for one time step.
        forward_velocity_ms: predicted vehicle speed
        yaw_rate_rads: gyroscope yaw rate (Z-axis)
        dt: time step in seconds
        """
        # 1. Update heading
        self.heading_rad += yaw_rate_rads * dt
        
        # 2. Compute displacements (NHC assumes velocity is purely forward)
        distance = forward_velocity_ms * dt
        
        # Standard convention: 0 heading = North, pi/2 = East
        # Usually from IMU: X=East, Y=North, Z=Up
        dx = distance * np.sin(self.heading_rad)  # East
        dy = distance * np.cos(self.heading_rad)  # North
        
        # 3. Update geographic coordinates
        lat_rad = np.radians(self.lat)
        
        # Change in latitude (1 radian of lat = R meters)
        dlat_rad = dy / self.R
        
        # Change in longitude (1 radian of lon = R * cos(lat) meters)
        dlon_rad = dx / (self.R * np.cos(lat_rad))
        
        self.lat += np.degrees(dlat_rad)
        self.lon += np.degrees(dlon_rad)
        
        self.trajectory.append((self.lat, self.lon))
        
        return self.lat, self.lon, self.heading_rad
        
    def get_trajectory(self):
        return np.array(self.trajectory)
