/**
 * Synchronized replay engine for the 5-model experiment.
 * Manages independent dead reckoning state for each model during GPS outage.
 */
import { DeadReckoner } from './integrator.js';
import { haversine } from './integrator.js';

export class ReplayEngine {
  /**
   * @param {Object} tripData - from benchmarkData.trips[tripId]
   * @param {Object} modelDataMap - map of modelId -> {model, normParams} for live models
   * @param {Object} modelMetadataMap - map of modelId -> metadata from benchmark
   * @param {Object} options - {zuptAssist: boolean, liveCnn: boolean}
   */
  constructor(tripData, modelDataMap, modelMetadataMap, options = {}) {
    this.tripData = tripData;
    this.modelDataMap = modelDataMap; // {modelId: {model, normParams}}
    this.modelMetadataMap = modelMetadataMap;
    this.options = options;
    
    // Experiment state
    this.phase = 'idle'; // 'idle' | 'gps' | 'outage' | 'done'
    this.outageStartIndex = tripData.outageStart;
    this.outageDuration = tripData.outageDuration;
    this.gpsStartIndex = Math.max(0, this.outageStartIndex - 180); // 3 min context
    
    // Initialize independent state for each model
    this.modelStates = new Map();
    const initLat = tripData.ref.lat[this.outageStartIndex];
    const initLon = tripData.ref.lon[this.outageStartIndex];
    const initHeadingDeg = tripData.ref.heading[this.outageStartIndex];
    
    for (const [modelId, metadata] of Object.entries(modelMetadataMap)) {
      const color = this._getModelColor(modelId);
      const integ = new DeadReckoner(initLat, initLon, initHeadingDeg);
      
      this.modelStates.set(modelId, {
        id: modelId,
        name: this._getModelName(modelId),
        color: color,
        integ: integ,
        // Trajectory history (lat, lon pairs)
        trajectory: [[initLat, initLon]],
        // Error history (meters) - distance from ground truth
        positionErrors: [],
        // Velocity history (m/s) - predicted vs reference
        velocityHistory: [],
        velocityErrorHistory: [],
        // Heading history (degrees)
        headingHistory: [initHeadingDeg],
        // Position error over time (for charts)
        positionErrorHistory: [0],
        // Reference velocity history (for charts)
        refVelocityHistory: [],
        // Statistics
        maxPositionError: 0,
        totalPositionError: 0,
        positionErrorCount: 0,
        // Flag if this model uses live TF.js inference
        usesLiveInference: this.options.liveCnn && modelId === 'cnn_feature_c'
      });
    }
  }
  
  _getModelName(modelId) {
    const names = {
      'cnn_baseline': 'CNN Baseline',
      'cnn_feature_c': 'Feature C CNN',
      'gru': 'GRU',
      'tcn': 'TCN',
      'xgboost': 'XGBoost',
      'cnn_feature_c_lowspeed': 'Feature C CNN (Low-Speed Exp)'
    };
    return names[modelId] || modelId;
  }
  
  _getModelColor(modelId) {
    const colors = {
      'cnn_baseline': '#ff6b6b',
      'cnn_feature_c': '#4ecdc4', 
      'gru': '#45b7d1',
      'tcn': '#96ceb4',
      'xgboost': '#ffeaa7',
      'cnn_feature_c_lowshed': '#dda0dd' // plum
    };
    return colors[modelId] || '#95a5a6';
  }
  
  /**
   * Start the experiment (call after constructor)
   * Sets up initial state for GPS phase
   */
  start() {
    this.phase = 'idle';
  }
  
  /**
   * Begin GPS phase - vehicle follows reference trajectory
   * @param {number} refIndex - current reference index during GPS phase
   */
  beginGpsPhase(refIndex) {
    this.phase = 'gps';
    this.currentRefIndex = refIndex;
    
    // Reset all model states to origin (last known good GPS position)
    for (const state of this.modelStates.values()) {
      // Reset trajectory to origin point only
      const originLat = this.tripData.ref.lat[this.outageStartIndex];
      const originLon = this.tripData.ref.lon[this.outageStartIndex];
      state.trajectory = [[originLat, originLon]];
      state.positionErrors = [];
      state.velocityHistory = [];
      state.velocityErrorHistory = [];
      state.headingHistory = [this.tripData.ref.heading[this.outageStartIndex]];
      state.refVelocityHistory = [];
      state.maxPositionError = 0;
      state.totalPositionError = 0;
      state.positionErrorCount = 0;
      
      // Reset integrator to origin
      const initLat = this.tripData.ref.lat[this.outageStartIndex];
      const initLon = this.tripData.ref.lon[this.outageStartIndex];
      const initHeadingDeg = this.tripData.ref.heading[this.outageStartIndex];
      state.integ = new DeadReckoner(initLat, initLon, initHeadingDeg);
    }
  }
  
  /**
   * Begin outage phase - GPS denied, models start dead reckoning
   * Called when user clicks TURN OFF GPS
   */
  beginOutagePhase() {
    this.phase = 'outage';
    this.outageStep = 0; // 0..outageDuration-1
    this.gpsFinishedIndex = this.outageStartIndex; // last GPS point before outage
  }
  
  /**
   * Advance experiment by one time step (1 second)
   * @returns {Object|null} snapshot of current state for rendering, null if done
   */
  step() {
    if (this.phase === 'idle' || this.phase === 'done') {
      return null;
    }
    
    if (this.phase === 'gps') {
      return this._stepGpsPhase();
    } else if (this.phase === 'outage') {
      return this._stepOutagePhase();
    }
    
    return null;
  }
  
  _stepGpsPhase() {
    // During GPS phase, vehicle follows reference trajectory
    // Models are not estimating - they wait for outage
    
    const refIndex = this.currentRefIndex;
    if (refIndex >= this.outageStartIndex) {
      // Reached outage start - automatically begin outage
      this.beginOutagePhase();
      return this._stepOutagePhase(); // process first outage step
    }
    
    // Advance GPS phase
    this.currentRefIndex++;
    
    // Build snapshot for rendering
    const snapshot = {
      phase: 'gps',
      refIndex: this.currentRefIndex - 1, // last displayed point
      gpsFinishedIndex: this.currentRefIndex - 1,
      outageStartIndex: this.outageStartIndex,
      models: {} // no model estimates during GPS
    };
    
    // Add reference position for this step
    snapshot.refPosition = [
      this.tripData.ref.lat[this.currentRefIndex - 1],
      this.tripData.ref.lon[this.currentRefIndex - 1]
    ];
    
    return snapshot;
  }
  
  _stepOutagePhase() {
    if (this.outageStep >= this.outageDuration) {
      this.phase = 'done';
      return this._buildDoneSnapshot();
    }
    
    const outageIndex = this.outageStartIndex + this.outageStep;
    const refLat = this.tripData.ref.lat[outageIndex];
    const refLon = this.tripData.ref.lon[outageIndex];
    const refVel = this.tripData.ref.vel[outageIndex];
    const refHeading = this.tripData.ref.heading[outageIndex];
    const gyroZ = this.tripData.ref.gyroZ[outageIndex];
    const stationary = this.tripData.stationary[outageIndex];
    
    // Update each model independently
    for (const [modelId, state] of this.modelStates.entries()) {
      // Get predicted velocity for this model at this step
      let velocityMs;
      if (state.usesLiveInference) {
        // Live TF.js inference - would be called from App via callback
        // For engine step, we use replayed velocity (live mode handled externally)
        velocityMs = this.tripData.models[modelId].outage.vel[this.outageStep];
      } else {
        // Replayed velocity from benchmark
        velocityMs = this.tripData.models[modelId].outage.vel[this.outageStep];
      }
      
      // Apply ZUPT assist if enabled
      const zuptAssist = this.options.zuptAssist && Boolean(stationary);
      
      // Step the integrator
      const [lat, lon] = state.integ.step(
        velocityMs, 
        gyroZ, 
        zuptAssist
      );
      
      // Record state
      state.trajectory.push([lat, lon]);
      state.headingHistory.push(state.integ.getHeadingDeg());
      
      // Calculate error vs ground truth
      const errorM = haversine(refLat, refLon, lat, lon);
      state.positionErrors.push(errorM);
      state.positionErrorHistory.push(errorM);
      state.totalPositionError += errorM;
      state.positionErrorCount++;
      
      if (errorM > state.maxPositionError) {
        state.maxPositionError = errorM;
      }
      
      // Velocity and heading history
      state.velocityHistory.push(velocityMs);
      state.velocityErrorHistory.push(velocityMs - refVel);
      state.refVelocityHistory.push(refVel);
      state.headingHistory.push(state.integ.getHeadingDeg());
    }
    
    this.outageStep++;
    
    // Build snapshot for rendering
    return this._buildSnapshot();
  }
  
  _buildSnapshot() {
    const latestOutageIndex = this.outageStartIndex + Math.max(0, this.outageStep - 1);
    
    const modelSnapshots = {};
for (const [modelId, state] of this.modelStates.entries()) {
modelSnapshots[modelId] = {
          name: state.name,
          color: state.color,
          trajectory: [...state.trajectory], // copy array
          positionError: state.positionErrors.slice(-1)[0] || 0,
          maxPositionError: state.maxPositionError,
          avgPositionError: state.positionErrorCount > 0 
            ? state.totalPositionError / state.positionErrorCount 
            : 0,
          velocity: state.velocityHistory.slice(-1)[0] || 0,
          velocityError: state.velocityErrorHistory.slice(-1)[0] || 0,
          heading: state.headingHistory.slice(-1)[0] || 0,
          refVelocity: state.refVelocityHistory.slice(-1)[0] || 0,
          distanceTraveled: this._calculateDistanceTraveled(state.trajectory),
          usesLiveInference: state.usesLiveInference,
          zuptAssistActive: this.options.zuptAssist && 
                           this.outageStep > 0 && 
                           Boolean(this.tripData.stationary[this.outageStartIndex + this.outageStep - 1]),
          // History arrays for charts
          positionErrorHistory: [...state.positionErrors],
          velocityHistory: [...state.velocityHistory],
          headingHistory: [...state.headingHistory],
          refVelocityHistory: [...state.refVelocityHistory]
        };
     }
    
    return {
      phase: 'outage',
      outageStep: this.outageStep,
      outageDuration: this.outageDuration,
      refIndex: this.outageStartIndex + this.outageStep - 1,
      gpsFinishedIndex: this.outageStartIndex - 1,
      models: modelSnapshots,
      referencePosition: [
        this.tripData.ref.lat[latestOutageIndex],
        this.tripData.ref.lon[latestOutageIndex]
      ],
      referenceVelocity: this.tripData.ref.vel[latestOutageIndex] || 0,
      stationaryActive: this.outageStep > 0 && 
                       Boolean(this.tripData.stationary[this.outageStartIndex + this.outageStep - 1])
    };
  }
  
  _buildDoneSnapshot() {
    this.phase = 'done';
    return this._buildSnapshot();
  }
  
  _calculateDistanceTraveled(trajectory) {
    if (trajectory.length < 2) return 0;
    let total = 0;
    for (let i = 1; i < trajectory.length; i++) {
      const [lat1, lon1] = trajectory[i-1];
      const [lat2, lon2] = trajectory[i];
      total += haversine(lat1, lon1, lat2, lon2);
    }
    return total;
  }
  
  /**
   * Reset experiment to initial state
   */
  reset() {
    this.phase = 'idle';
    this.outageStep = 0;
    this.currentRefIndex = this.gpsStartIndex;
    // Model states will be reinitialized when beginGpsPhase is called
  }
  
  /**
   * Get experiment progress (0-1)
   * @returns {number} progress ratio
   */
  getProgress() {
    if (this.phase === 'idle') return 0;
    if (this.phase === 'gps') {
      const gpsProgress = (this.currentRefIndex - this.gpsStartIndex) / 
                         Math.max(1, this.outageStartIndex - this.gpsStartIndex);
      return gpsProgress * 0.5; // GPS phase is first half
    } else if (this.phase === 'outage') {
      return 0.5 + (0.5 * (this.outageStep / this.outageDuration));
    } else {
      return 1.0;
    }
  }
  
  /**
   * Check if experiment is done
   * @returns {boolean}
   */
  isDone() {
    return this.phase === 'done';
  }
  
  /**
   * Get final results for comparison table
   * @returns {Object} map of modelId -> final metrics
   */
  getFinalResults() {
    const results = {};
    for (const [modelId, state] of this.modelStates.entries()) {
      results[modelId] = {
        finalPositionErrorM: state.positionErrors.slice(-1)[0] || 0,
        maxPositionErrorM: state.maxPositionError,
        avgPositionErrorM: state.positionErrorCount > 0 
          ? state.totalPositionError / state.positionErrorCount 
          : 0,
        finalVelocityErrorMps: state.velocityErrorHistory.slice(-1)[0] || 0,
        distanceTraveledM: this._calculateDistanceTraveled(state.trajectory)
      };
    }
    return results;
  }
}