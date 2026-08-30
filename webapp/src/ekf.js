export class EKF {
  constructor(initialLat, initialLon, initialHeadingRad) {
    this.R = 6378137.0;
    this.originLat = initialLat;
    this.originLon = initialLon;
    
    // State: [x, y, heading_rad, v]
    this.x = [0.0, 0.0, initialHeadingRad, 0.0];
  }

  latLonToXy(lat, lon) {
    const latRad = lat * (Math.PI / 180.0);
    const origLatRad = this.originLat * (Math.PI / 180.0);
    
    const dx = (lon - this.originLon) * (Math.PI / 180.0) * this.R * Math.cos(origLatRad);
    const dy = (lat - this.originLat) * (Math.PI / 180.0) * this.R;
    return [dx, dy];
  }

  xyToLatLon(x, y) {
    const origLatRad = this.originLat * (Math.PI / 180.0);
    
    const lat = this.originLat + (y / this.R) * (180.0 / Math.PI);
    const lon = this.originLon + (x / (this.R * Math.cos(origLatRad))) * (180.0 / Math.PI);
    return [lat, lon];
  }

  predict(dt, mlVelocity, gyroYawRate) {
    const [x, y, theta, v] = this.x;
    
    // Kinematic model update
    const newX = x + v * Math.sin(theta) * dt;
    const newY = y + v * Math.cos(theta) * dt;
    const newTheta = theta + gyroYawRate * dt;
    const newV = mlVelocity; // Direct replacement from ML
    
    this.x = [newX, newY, newTheta, newV];
  }
  
  getLatLon() {
    return this.xyToLatLon(this.x[0], this.x[1]);
  }
}
