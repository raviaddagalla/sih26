export interface Coordinate {
  lat: number;
  lng: number;
}

export type AppPhase =
  | 'calibration'
  | 'map'
  | 'route-preview'
  | 'simulating'
  | 'completed';

export type GPSState = 'available' | 'disabled' | 'restoring';

export interface RouteSegment {
  startIdx: number;
  endIdx: number;
  startDistance: number;
  endDistance: number;
}
