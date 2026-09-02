import type { Coordinate } from '../simulation/types';

const R = 6371e3; // Earth radius in meters

export function toRadians(degrees: number): number {
  return (degrees * Math.PI) / 180;
}

export function toDegrees(radians: number): number {
  return (radians * 180) / Math.PI;
}

/** Returns distance in meters */
export function haversineDistance(c1: Coordinate, c2: Coordinate): number {
  const dLat = toRadians(c2.lat - c1.lat);
  const dLng = toRadians(c2.lng - c1.lng);
  const lat1 = toRadians(c1.lat);
  const lat2 = toRadians(c2.lat);

  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.sin(dLng / 2) * Math.sin(dLng / 2) * Math.cos(lat1) * Math.cos(lat2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

/** Returns initial bearing in degrees from c1 to c2 */
export function calculateBearing(c1: Coordinate, c2: Coordinate): number {
  const lat1 = toRadians(c1.lat);
  const lat2 = toRadians(c2.lat);
  const dLng = toRadians(c2.lng - c1.lng);

  const y = Math.sin(dLng) * Math.cos(lat2);
  const x =
    Math.cos(lat1) * Math.sin(lat2) -
    Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLng);
  const brng = Math.atan2(y, x);

  return (toDegrees(brng) + 360) % 360;
}

/** Interpolates between two coordinates given a fraction (0 to 1) */
export function interpolateCoordinate(c1: Coordinate, c2: Coordinate, fraction: number): Coordinate {
  return {
    lat: c1.lat + (c2.lat - c1.lat) * fraction,
    lng: c1.lng + (c2.lng - c1.lng) * fraction,
  };
}

/** Calculates total distance of a route and returns distances array */
export function analyzeRoute(route: Coordinate[]): { totalDistance: number; distances: number[] } {
  if (route.length < 2) return { totalDistance: 0, distances: [0] };
  
  const distances = [0];
  let totalDistance = 0;
  for (let i = 1; i < route.length; i++) {
    const d = haversineDistance(route[i - 1], route[i]);
    totalDistance += d;
    distances.push(totalDistance);
  }
  return { totalDistance, distances };
}

/** Finds the coordinate at a specific distance along the route */
export function getCoordinateAtDistance(route: Coordinate[], distances: number[], targetDistance: number): Coordinate {
  if (route.length === 0) return { lat: 0, lng: 0 };
  if (targetDistance <= 0) return route[0];
  const total = distances[distances.length - 1];
  if (targetDistance >= total) return route[route.length - 1];

  // Find the segment
  for (let i = 0; i < distances.length - 1; i++) {
    if (targetDistance >= distances[i] && targetDistance <= distances[i + 1]) {
      const segmentDist = distances[i + 1] - distances[i];
      const fraction = segmentDist === 0 ? 0 : (targetDistance - distances[i]) / segmentDist;
      return interpolateCoordinate(route[i], route[i + 1], fraction);
    }
  }
  
  return route[route.length - 1];
}

/** Creates a drift using a pseudo random seeded value to be deterministic */
export function seededRandom(seed: number) {
  const x = Math.sin(seed++) * 10000;
  return x - Math.floor(x);
}
