"""
Error-State Kalman Filter (ESKF) for 3D Vehicle Tracking with NHC.
Implements Dynamic IMU Alignment and Data-Driven Velocity/Covariance Updates.
"""
import numpy as np
from scipy.spatial.transform import Rotation as R

class ESKF:
    def __init__(self, init_lat, init_lon, init_heading_rad, init_v=0.0):
        self.R_earth = 6378137.0
        self.origin_lat = init_lat
        self.origin_lon = init_lon
        
        # Nominal State:
        # p: position (x,y,z) in local NED frame
        # v: velocity (vx,vy,vz) in local NED frame
        # q: orientation (quaternion) from Body to NED
        # bg: gyro bias
        # ba: accel bias
        
        self.p = np.array([0.0, 0.0, 0.0])
        self.v = np.array([init_v * np.cos(init_heading_rad), 
                           init_v * np.sin(init_heading_rad), 0.0])
        
        # Initialize orientation: assume flat vehicle, heading = init_heading_rad
        # Using ZYX Euler angles (yaw, pitch, roll) -> (init_heading_rad, 0, 0)
        self.q = R.from_euler('ZYX', [init_heading_rad, 0, 0]).as_quat() # [x, y, z, w]
        
        self.bg = np.zeros(3)
        self.ba = np.zeros(3)
        
        self.g = np.array([0.0, 0.0, 9.81]) # Gravity in NED is +Z
        
        # Error State Covariance (15x15)
        # Order: [delta_p (3), delta_v (3), delta_theta (3), delta_bg (3), delta_ba (3)]
        self.P = np.eye(15) * 1e-4
        self.P[6:9, 6:9] = np.eye(3) * (np.pi/4)**2 # High initial heading uncertainty
        
        # Process Noise Covariance (12x12 for v_noise, theta_noise, bg_noise, ba_noise)
        self.Q = np.diag([
            0.1**2, 0.1**2, 0.1**2,       # accel noise
            0.01**2, 0.01**2, 0.01**2,    # gyro noise
            0.001**2, 0.001**2, 0.001**2, # accel bias random walk
            0.0001**2, 0.0001**2, 0.0001**2 # gyro bias random walk
        ])

    def predict(self, dt, accel, gyro):
        """
        Integrate raw IMU data.
        accel: [ax, ay, az] in body frame
        gyro: [wx, wy, wz] in body frame
        """
        # Correct IMU measurements with biases
        a_b = accel - self.ba
        w_b = gyro - self.bg
        
        rot = R.from_quat(self.q)
        C_bn = rot.as_matrix() # Body to NED rotation
        
        # 1. Update nominal state
        a_n = C_bn @ a_b + self.g
        
        self.p = self.p + self.v * dt + 0.5 * a_n * dt**2
        self.v = self.v + a_n * dt
        
        delta_q = R.from_rotvec(w_b * dt).as_quat()
        # Quaternion multiply
        # scipy format: [x,y,z,w]. multiplication: R1 * R2
        self.q = (rot * R.from_rotvec(w_b * dt)).as_quat()
        
        # 2. Update error state covariance
        F = np.eye(15)
        F[0:3, 3:6] = np.eye(3) * dt
        
        # dv / dtheta = -C_bn * (a_b x) * dt
        a_b_skew = np.array([
            [0, -a_b[2], a_b[1]],
            [a_b[2], 0, -a_b[0]],
            [-a_b[1], a_b[0], 0]
        ])
        F[3:6, 6:9] = -C_bn @ a_b_skew * dt
        F[3:6, 12:15] = -C_bn * dt
        
        # dtheta / dtheta = exp(-(w_b x) * dt) ~ I - (w_b x) * dt
        w_b_skew = np.array([
            [0, -w_b[2], w_b[1]],
            [w_b[2], 0, -w_b[0]],
            [-w_b[1], w_b[0], 0]
        ])
        F[6:9, 6:9] = np.eye(3) - w_b_skew * dt
        F[6:9, 9:12] = -np.eye(3) * dt
        
        # Noise matrix L (15x12)
        L = np.zeros((15, 12))
        L[3:6, 0:3] = C_bn * dt
        L[6:9, 3:6] = np.eye(3) * dt
        L[9:12, 6:9] = np.eye(3) * dt
        L[12:15, 9:12] = np.eye(3) * dt
        
        self.P = F @ self.P @ F.T + L @ self.Q @ L.T

    def update_ml_velocity(self, v_ml, R_ml):
        """
        Update with DL-predicted forward velocity.
        v_ml: scalar forward speed
        R_ml: dynamic measurement variance from FilterParameterAdapter
        """
        rot = R.from_quat(self.q)
        C_bn = rot.as_matrix()
        C_nb = C_bn.T
        
        # The true velocity in body frame is C_nb @ v
        # We assume v_ml is the forward velocity (x-axis in vehicle frame)
        # So measurement z = v_ml. Model h(x) = (C_nb @ v)[0]
        
        v_b = C_nb @ self.v
        z_est = v_b[0]
        z_meas = v_ml
        
        # Jacobian H (1x15)
        # h(x) = e1^T * C_nb @ v
        # dh/dv = e1^T * C_nb
        # dh/dtheta = e1^T * (v_b x)
        H = np.zeros((1, 15))
        H[0, 3:6] = C_nb[0, :]
        
        v_b_skew = np.array([
            [0, -v_b[2], v_b[1]],
            [v_b[2], 0, -v_b[0]],
            [-v_b[1], v_b[0], 0]
        ])
        H[0, 6:9] = v_b_skew[0, :]
        
        # Innovation
        y = z_meas - z_est
        S = H @ self.P @ H.T + R_ml
        K = self.P @ H.T @ np.linalg.inv(S)
        
        dx = K @ np.array([y])
        self.inject_error_state(dx)
        self.P = (np.eye(15) - K @ H) @ self.P
        
    def update_nhc(self):
        """
        Non-Holonomic Constraints: Lateral and vertical velocity in body frame ~ 0.
        """
        rot = R.from_quat(self.q)
        C_bn = rot.as_matrix()
        C_nb = C_bn.T
        
        v_b = C_nb @ self.v
        z_est = v_b[1:3] # y and z components in body frame
        z_meas = np.array([0.0, 0.0])
        
        H = np.zeros((2, 15))
        H[:, 3:6] = C_nb[1:3, :]
        
        v_b_skew = np.array([
            [0, -v_b[2], v_b[1]],
            [v_b[2], 0, -v_b[0]],
            [-v_b[1], v_b[0], 0]
        ])
        H[:, 6:9] = v_b_skew[1:3, :]
        
        R_nhc = np.diag([0.1**2, 0.1**2]) # Tight constraints
        
        y = z_meas - z_est
        S = H @ self.P @ H.T + R_nhc
        K = self.P @ H.T @ np.linalg.inv(S)
        
        dx = K @ y
        self.inject_error_state(dx)
        self.P = (np.eye(15) - K @ H) @ self.P

    def inject_error_state(self, dx):
        dp, dv, dtheta, dbg, dba = dx[0:3], dx[3:6], dx[6:9], dx[9:12], dx[12:15]
        
        self.p += dp
        self.v += dv
        self.bg += dbg
        self.ba += dba
        
        dq = R.from_rotvec(dtheta).as_quat()
        self.q = (R.from_quat(self.q) * R.from_quat(dq)).as_quat()
        
    def xy_to_latlon(self, x, y):
        lat = self.origin_lat + np.degrees(y / self.R_earth)
        lon = self.origin_lon + np.degrees(x / (self.R_earth * np.cos(np.radians(self.origin_lat))))
        return lat, lon
        
    def get_latlon(self):
        # p is in NED, so x=North, y=East
        lat, lon = self.xy_to_latlon(self.p[1], self.p[0])
        return lat, lon
