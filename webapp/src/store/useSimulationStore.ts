import { create } from 'zustand';
import type { AppPhase, Coordinate, GPSState } from '../simulation/types';

interface SimulationState {
  phase: AppPhase;
  gpsState: GPSState;
  
  // Configuration
  demoMode: boolean;
  realWorldDuration: number; // in seconds
  simulationDuration: number; // in seconds
  estimationErrorPercent: number;
  
  // Routing
  origin: Coordinate | null;
  destination: Coordinate | null;
  routeCoordinates: Coordinate[];
  routeDistances: number[];
  totalRouteDistance: number;
  
  // Simulation Progress (Updated frequently)
  progress: number; // 0 to 1
  simulatedElapsedTime: number; // in seconds
  playbackElapsedTime: number; // in seconds
  
  // Positions (Updated 60fps, components should subscribe directly via refs to avoid re-renders if possible)
  groundTruthPosition: Coordinate | null;
  estimatedPosition: Coordinate | null;
  displayedPosition: Coordinate | null;
  
  heading: number;
  speed: number; // m/s
  
  // Track History (For drawing the paths)
  gpsTrackHistory: Coordinate[][];
  estimatedTrackHistory: Coordinate[][];

  // Actions
  setPhase: (phase: AppPhase) => void;
  setGPSState: (state: GPSState) => void;
  setRoute: (route: Coordinate[], distances: number[], totalDistance: number) => void;
  setLocations: (origin: Coordinate, destination: Coordinate) => void;
  resetSimulation: () => void;
}

const initialState = {
  phase: 'calibration' as AppPhase,
  gpsState: 'available' as GPSState,
  
  demoMode: true,
  realWorldDuration: 1800, // 30 mins
  simulationDuration: 120, // 2 mins
  estimationErrorPercent: 0.015,
  
  origin: null,
  destination: null,
  routeCoordinates: [],
  routeDistances: [],
  totalRouteDistance: 0,
  
  progress: 0,
  simulatedElapsedTime: 0,
  playbackElapsedTime: 0,
  
  groundTruthPosition: null,
  estimatedPosition: null,
  displayedPosition: null,
  
  heading: 0,
  speed: 0,
  
  gpsTrackHistory: [],
  estimatedTrackHistory: [],
};

export const useSimulationStore = create<SimulationState>()((set) => ({
  ...initialState,
  
  setPhase: (phase) => set({ phase }),
  
  setGPSState: (state) => set({ gpsState: state }),
  
  setRoute: (routeCoordinates, routeDistances, totalRouteDistance) => 
    set({ routeCoordinates, routeDistances, totalRouteDistance }),
    
  setLocations: (origin, destination) => set({ origin, destination }),
  
  resetSimulation: () => set({
    ...initialState,
    phase: 'route-preview',
    // Preserve route configuration if it exists
  }),
}));
