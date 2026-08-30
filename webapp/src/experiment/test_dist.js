import { haversine } from './integrator.js';

const trajectory = [
  [37.7749, -122.4194],
  [37.7750, -122.4194],
  [37.7751, -122.4194]
];

function calculateDistanceTraveled(trajectory) {
    if (trajectory.length < 2) return 0;
    let total = 0;
    for (let i = 1; i < trajectory.length; i++) {
      const [lat1, lon1] = trajectory[i-1];
      const [lat2, lon2] = trajectory[i];
      total += haversine(lat1, lon1, lat2, lon2);
    }
    return total;
}

console.log(calculateDistanceTraveled(trajectory));
