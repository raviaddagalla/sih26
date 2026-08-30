/**
 * Dead reckoning integrator for the webapp experiment.
 * Implements the same math as the fixed Python dead_reckon in evaluate_all.py
 * to ensure parity between offline benchmark and online demo.
 */
export class DeadReckoner {
  /**
   * @param {number} initLatDeg - initial latitude in degrees
   * @param {number} initLonDeg - initial longitude in degrees
   * @param {number} initHeadingDeg - initial heading in degrees (0 = North, 90 = East)
   */
  constructor(initLatDeg, initLonDeg, initHeadingDeg) {
    this.R = 6378137.0; // Earth radius in meters
    this.originLat = initLatDeg;
    this.originLon = initLonDeg;
    
    // State: [x, y, heading_rad, velocity_mps]
    // x: East, y: North in local ENU frame centered at origin
    this.x = [0.0, 0.0, initHeadingDeg * (Math.PI / 180.0), 0.0];
  }

  /**
   * Convert latitude/longitude to local ENU coordinates (meters)
   * @param {number} latDeg 
   * @param {number} lonDeg 
   * @returns {[number, number]} [x_east_m, y_north_m]
   */
  latLonToXy(latDeg, lonDeg) {
    const latRad = latDeg * (Math.PI / 180.0);
    const origLatRad = this.originLat * (Math.PI / 180.0);
    
    const dx = (lonDeg - this.originLon) * (Math.PI / 180.0) * this.R * Math.cos(origLatRad);
    const dy = (latDeg - this.originLat) * (Math.PI / 180.0) * this.R;
    return [dx, dy];
  }

  /**
   * Convert local ENU coordinates back to latitude/longitude
   * @param {number} x_east 
   * @param {number} y_north 
   * @returns {[number, number]} [latDeg, lonDeg]
   */
  xyToLatLon(x, y) {
    const origLatRad = this.originLat * (Math.PI / 180.0);
    
    const lat = this.originLat + (y / this.R) * (180.0 / Math.PI);
    const lon = this.originLon + (x / (this.R * Math.cos(origLatRad))) * (180.0 / Math.PI);
    return [lat, lon];
  }

  /**
   * Perform one dead reckoning step (1 second dt)
   * @param {number} velocityMps - forward velocity from model (m/s)
   * @param {number} gyroYawRateRadPerSec - yaw rate from gyroscope (rad/s)
   * @param {boolean} zupt - if true, force velocity to zero (ZUPT assist)
   * @returns {[number, number]} [latDeg, lonDeg] current position
   */
  step(velocityMps, gyroYawRateRadPerSec, zupt = false) {
    const [x, y, theta, v] = this.x;
    
    // Apply ZUPT if requested
    const effVelocity = zupt ? 0.0 : velocityMps;
    
    // Kinematic model update (matches fixed Python dead_reckon)
    const dist = effVelocity * 1.0; // dt = 1.0 s
    const newTheta = theta + gyroYawRateRadPerSec * 1.0;
    
    // Step displacement
    const dx = dist * Math.sin(newTheta);
    const dy = dist * Math.cos(newTheta);
    
    // Update position (keeping same order as Python: heading update first)
    const newX = x + dx;
    const newY = y + dy;
    
    this.x = [newX, newY, newTheta, effVelocity];
    
    // Return current lat/lon
    return this.xyToLatLon(newX, newY);
  }

  /**
   * Get current position as [latDeg, lonDeg]
   * @returns {[number, number]}
   */
  getLatLon() {
    return this.xyToLatLon(this.x[0], this.x[1]);
  }

  /**
   * Get current heading in degrees [0, 360)
   * @returns {number}
   */
  getHeadingDeg() {
    let headingDeg = this.x[2] * (180.0 / Math.PI);
    // Normalize to [0, 360)
    while (headingDeg < 0) headingDeg += 360;
    while (headingDeg >= 360) headingDeg -= 360;
    return headingDeg;
  }
}

/**
 * Haversine distance between two lat/lon points (meters)
 * @param {number} lat1 
 * @param {number} lon1 
 * @param {number} lat2 
 * @param {number} lon2 
 * @returns {number} distance in meters
 */
export function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371000; // Earth radius in meters
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a = 
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) * 
    Math.cos((lat2 * Math.PI) / 180) * 
    Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}