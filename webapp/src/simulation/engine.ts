import { useSimulationStore } from '../store/useSimulationStore';
import type { Coordinate, GPSState } from './types';
import { getCoordinateAtDistance, calculateBearing } from '../geo/math';

class SimulationEngine {
  private animationFrameId: number | null = null;
  private lastTimestamp: number = 0;
  private isRunning: boolean = false;
  
  private playbackElapsedTime: number = 0;
  
  // Estimation variables
  private seed: number = 42;
  private driftX: number = 0;
  private driftY: number = 0;
  
  // Restoration animation
  private restoringStartTime: number | null = null;
  private restoringStartPos: Coordinate | null = null;
  private readonly RESTORE_DURATION_MS = 2000;

  // Track history accumulators
  private lastTrackUpdateDistance: number = 0;
  private lastGpsState: GPSState = 'available';
  private startNewGpsSegment: boolean = true;
  private startNewEstSegment: boolean = true;

  private pseudoRandom() {
    const x = Math.sin(this.seed++) * 10000;
    return x - Math.floor(x);
  }

  public start() {
    if (this.isRunning) return;
    this.isRunning = true;
    this.lastTimestamp = performance.now();
    this.animationFrameId = requestAnimationFrame(this.tick);
    
    useSimulationStore.getState().setPhase('simulating');
  }

  public pause() {
    this.isRunning = false;
    if (this.animationFrameId !== null) {
      cancelAnimationFrame(this.animationFrameId);
      this.animationFrameId = null;
    }
  }
  
  public stop() {
    this.pause();
    useSimulationStore.getState().setPhase('completed');
  }

  public reset() {
    this.pause();
    this.playbackElapsedTime = 0;
    this.seed = 42;
    this.driftX = 0;
    this.driftY = 0;
    this.restoringStartTime = null;
    this.restoringStartPos = null;
    this.lastTrackUpdateDistance = 0;
    this.lastGpsState = 'available';
    this.startNewGpsSegment = true;
    this.startNewEstSegment = true;
    useSimulationStore.getState().resetSimulation();
  }

  private tick = (timestamp: number) => {
    if (!this.isRunning) return;

    const deltaMs = timestamp - this.lastTimestamp;
    this.lastTimestamp = timestamp;

    this.update(deltaMs);

    this.animationFrameId = requestAnimationFrame(this.tick);
  };

  private update(deltaMs: number) {
    const state = useSimulationStore.getState();
    const { routeCoordinates, routeDistances, totalRouteDistance, simulationDuration, realWorldDuration, gpsState } = state;

    if (!routeCoordinates || routeCoordinates.length === 0 || totalRouteDistance === 0) return;

    // Update time
    this.playbackElapsedTime += deltaMs / 1000;
    
    // Clamp to simulation duration
    const progress = Math.min(this.playbackElapsedTime / simulationDuration, 1);
    
    const simulatedElapsedTime = progress * realWorldDuration;
    
    // Calculate ground truth
    const currentDistance = progress * totalRouteDistance;
    const groundTruthPosition = getCoordinateAtDistance(routeCoordinates, routeDistances, currentDistance);
    
    // Calculate heading (look slightly ahead)
    const lookAheadDistance = Math.min(currentDistance + 10, totalRouteDistance);
    const lookAheadPos = getCoordinateAtDistance(routeCoordinates, routeDistances, lookAheadDistance);
    const heading = calculateBearing(groundTruthPosition, lookAheadPos);

    // Calculate Speed (m/s)
    const speed = totalRouteDistance / realWorldDuration;

    let estimatedPosition = groundTruthPosition;
    let displayedPosition = groundTruthPosition;

    if (gpsState === 'disabled') {
      // Calculate drift relative to heading
      // We want a bounded drift. We'll use a random walk bounded by the estimationErrorPercent of total distance.
      const maxDrift = totalRouteDistance * state.estimationErrorPercent;
      
      // Gradually change drift
      this.driftX += (this.pseudoRandom() - 0.5) * 1.5; 
      this.driftY += (this.pseudoRandom() - 0.5) * 1.5;
      
      // Bound it
      const currentDriftMag = Math.sqrt(this.driftX * this.driftX + this.driftY * this.driftY);
      if (currentDriftMag > maxDrift) {
        this.driftX = (this.driftX / currentDriftMag) * maxDrift;
        this.driftY = (this.driftY / currentDriftMag) * maxDrift;
      }

      // Convert local offset (meters) to lat/lng based on Earth radius
      const R = 6371e3;
      const latOffset = (this.driftY / R) * (180 / Math.PI);
      const lngOffset = (this.driftX / (R * Math.cos(Math.PI * groundTruthPosition.lat / 180))) * (180 / Math.PI);
      
      estimatedPosition = {
        lat: groundTruthPosition.lat + latOffset,
        lng: groundTruthPosition.lng + lngOffset
      };
      displayedPosition = estimatedPosition;
      
    } else if (gpsState === 'restoring') {
      // Reset drift smoothly by interpolating from estimated to ground truth
      if (this.restoringStartTime === null) {
        this.restoringStartTime = performance.now();
        this.restoringStartPos = state.estimatedPosition || groundTruthPosition;
      }
      
      const elapsedRestore = performance.now() - this.restoringStartTime;
      const restoreFraction = Math.min(elapsedRestore / this.RESTORE_DURATION_MS, 1);
      
      // Easing function (easeOutCubic)
      const easeFraction = 1 - Math.pow(1 - restoreFraction, 3);
      
      displayedPosition = {
        lat: this.restoringStartPos!.lat + (groundTruthPosition.lat - this.restoringStartPos!.lat) * easeFraction,
        lng: this.restoringStartPos!.lng + (groundTruthPosition.lng - this.restoringStartPos!.lng) * easeFraction
      };
      
      estimatedPosition = displayedPosition;

      if (restoreFraction >= 1) {
        useSimulationStore.setState({ gpsState: 'available' });
        this.restoringStartTime = null;
        this.restoringStartPos = null;
        this.driftX = 0;
        this.driftY = 0;
      }
    } else {
      // Available
      estimatedPosition = groundTruthPosition;
      displayedPosition = groundTruthPosition;
      this.driftX = 0;
      this.driftY = 0;
      this.restoringStartTime = null;
    }

    if (gpsState !== this.lastGpsState) {
      if (gpsState === 'available') this.startNewGpsSegment = true;
      if (gpsState === 'disabled') this.startNewEstSegment = true;
      this.lastGpsState = gpsState;
    }

    // Track histories update (only add point every ~20 meters to avoid massive arrays)
    let { gpsTrackHistory, estimatedTrackHistory } = state;
    if (currentDistance - this.lastTrackUpdateDistance > 20) {
      if (gpsState === 'available') {
         if (this.startNewGpsSegment || gpsTrackHistory.length === 0) {
           gpsTrackHistory = [...gpsTrackHistory, []];
           this.startNewGpsSegment = false;
         }
         const currentSegment = [...gpsTrackHistory[gpsTrackHistory.length - 1], groundTruthPosition];
         gpsTrackHistory = [...gpsTrackHistory.slice(0, -1), currentSegment];
      } else if (gpsState === 'disabled') {
         if (this.startNewEstSegment || estimatedTrackHistory.length === 0) {
           estimatedTrackHistory = [...estimatedTrackHistory, []];
           this.startNewEstSegment = false;
         }
         const currentSegment = [...estimatedTrackHistory[estimatedTrackHistory.length - 1], estimatedPosition];
         estimatedTrackHistory = [...estimatedTrackHistory.slice(0, -1), currentSegment];
      }
      this.lastTrackUpdateDistance = currentDistance;
    }

    // Update store
    useSimulationStore.setState({
      progress,
      simulatedElapsedTime,
      playbackElapsedTime: this.playbackElapsedTime,
      groundTruthPosition,
      estimatedPosition,
      displayedPosition,
      heading,
      speed,
      gpsTrackHistory,
      estimatedTrackHistory
    });

    if (progress >= 1) {
      this.stop();
    }
  }
}

export const simulationEngine = new SimulationEngine();
