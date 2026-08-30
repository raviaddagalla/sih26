"""
Phase 3: EKF Fusion
Extended Kalman Filter for fusing IMU velocity/heading with intermittent GNSS.
"""
import numpy as np

class EKF:
    """
    Extended Kalman Filter for 2D Vehicle Tracking.
    State vector: [x, y, heading, velocity]
    """
    def __init__(self, initial_lat, initial_lon, initial_heading, initial_velocity=0.0):
        # Earth radius for coordinate conversion
        self.R = 6378137.0
        
        # Origin for local Cartesian projection
        self.origin_lat = initial_lat
        self.origin_lon = initial_lon
        
        # State [x, y, heading, v]
        self.x = np.array([0.0, 0.0, initial_heading, initial_velocity])
        
        # Covariance matrix
        self.P = np.eye(4) * 1.0
        
        # Process noise covariance (Q)
        # Tuning parameters (should ideally be derived from stationary noise estimates)
        self.Q = np.diag([
            0.1,    # x variance (process)
            0.1,    # y variance (process)
            0.01,   # heading variance
            0.5     # velocity variance
        ])
        
        # Measurement noise covariance (R)
        # For GPS position updates (x, y)
        self.R_gps = np.diag([10.0, 10.0])  # 10m variance
        
    def latlon_to_xy(self, lat, lon):
        """Convert lat/lon to local Cartesian coordinates (m) relative to origin."""
        lat_rad = np.radians(lat)
        orig_lat_rad = np.radians(self.origin_lat)
        
        dx = np.radians(lon - self.origin_lon) * self.R * np.cos(orig_lat_rad)
        dy = np.radians(lat - self.origin_lat) * self.R
        return dx, dy
        
    def xy_to_latlon(self, x, y):
        """Convert local Cartesian coordinates back to lat/lon."""
        orig_lat_rad = np.radians(self.origin_lat)
        
        lat = self.origin_lat + np.degrees(y / self.R)
        lon = self.origin_lon + np.degrees(x / (self.R * np.cos(orig_lat_rad)))
        return lat, lon

    def predict(self, dt, ml_velocity, gyro_yaw_rate):
        """
        Predict state using control inputs.
        Instead of treating ML velocity as an update, we can treat it as a control input,
        or we can drive the state forward using the kinematic model.
        Here we use a standard kinematic model where velocity and heading are part of the state,
        and we update them towards the sensor values.
        """
        x, y, theta, v = self.x
        
        # Update state via kinematic model (Euler integration)
        new_x = x + v * np.sin(theta) * dt
        new_y = y + v * np.cos(theta) * dt
        
        # We drive the state towards the IMU predictions
        # (This is a simplified filter structure where IMU acts as pseudo-measurements
        #  or direct state replacements depending on tuning)
        new_theta = theta + gyro_yaw_rate * dt
        new_v = ml_velocity # Replace state with ML prediction directly (strong confidence)
        
        self.x = np.array([new_x, new_y, new_theta, new_v])
        
        # Jacobian of the state transition matrix (F)
        F = np.array([
            [1, 0, v * np.cos(theta) * dt, np.sin(theta) * dt],
            [0, 1, -v * np.sin(theta) * dt, np.cos(theta) * dt],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ])
        
        # Update covariance
        self.P = F @ self.P @ F.T + self.Q

    def update_gps(self, gps_lat, gps_lon):
        """
        Update state with GPS measurement.
        """
        meas_x, meas_y = self.latlon_to_xy(gps_lat, gps_lon)
        z = np.array([meas_x, meas_y])
        
        # Measurement matrix H (we measure x and y)
        H = np.array([
            [1, 0, 0, 0],
            [0, 1, 0, 0]
        ])
        
        # Innovation (residual)
        y_res = z - (H @ self.x)
        
        # Innovation covariance
        S = H @ self.P @ H.T + self.R_gps
        
        # Kalman gain
        K = self.P @ H.T @ np.linalg.inv(S)
        
        # Update state
        self.x = self.x + K @ y_res
        
        # Update covariance
        I = np.eye(4)
        self.P = (I - K @ H) @ self.P
        
    def get_latlon(self):
        """Return current estimated lat/lon."""
        return self.xy_to_latlon(self.x[0], self.x[1])
