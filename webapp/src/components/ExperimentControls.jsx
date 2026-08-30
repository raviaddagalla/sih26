import React from 'react';

/**
 * Controls for starting/pausing/resetting the experiment
 * and configuring experimental parameters
 */
export default function ExperimentControls({
  experimentPhase,
  isRunning,
  onStart,
  onPause,
  onReset,
  onToggleGps,
  onSpeedChange,
  onZuputAssistToggle,
  onLiveCnnToggle,
  speed,
  zuptAssist,
  liveCnn,
  availableTrips,
  selectedTrip,
  onTripChange,
  progress = 0
}) {
  const getPhaseLabel = () => {
    switch (experimentPhase) {
      case 'idle': return 'Ready to Start';
      case 'gps': return 'GPS Phase - Collecting Reference';
      case 'outage': return 'GPS OUTAGE - Dead Reckoning Active';
      case 'done': return 'Experiment Complete';
      default: return 'Unknown';
    }
  };

  const getPhaseColor = () => {
    switch (experimentPhase) {
      case 'gps': return '#00b894';
      case 'outage': return '#e17055';
      case 'done': return '#0984e3';
      default: return '#636e72';
    }
  };

  return (
    <div className="controls-panel">
      <div className="controls-group">
        <label htmlFor="trip-select">Experiment Trip:</label>
        <select 
          id="trip-select"
          value={selectedTrip}
          onChange={(e) => onTripChange(e.target.value)}
          disabled={isRunning}
        >
          {availableTrips.map(trip => (
            <option key={trip} value={trip}>
              {trip.toUpperCase()}
            </option>
          ))}
        </select>
      </div>

      <div className="controls-group">
        <label>Experiment Phase:</label>
        <div className="stepper">
          <span className="step">IDLE</span>
          <span className="step">GPS</span>
          <span className="step">OUTAGE</span>
          <span className="step">DONE</span>
        </div>
        <div style={{marginTop: '0.5rem', fontWeight: 600, color: getPhaseColor()}}>
          {getPhaseLabel()}
        </div>
        {experimentPhase === 'outage' && (
          <div style={{marginTop: '0.5rem'}}>
            <label>Progress:</label>
            <progress value={progress} max={1} style={{width: '100%'}} />
          </div>
        )}
      </div>

      <div className="controls-group">
        <label htmlFor="speed-control">Playback Speed:</label>
        <div className="speed-control">
          <input
            type="range"
            id="speed-control"
            min="0.5"
            max="10"
            step="0.5"
            value={speed}
            onChange={(e) => onSpeedChange(parseFloat(e.target.value))}
          />
          <span className="speed-value">{speed}x</span>
        </div>
      </div>

      <div className="controls-group">
        <label htmlFor="zuput-toggle">
          <input
            type="checkbox"
            id="zuput-toggle"
            checked={zuptAssist}
            onChange={onZuputAssistToggle}
          />
          ZUPT Assist (IMU-based stationary detection)
        </label>
      </div>

      <div className="controls-group">
        <label htmlFor="live-cnn-toggle">
          <input
            type="checkbox"
            id="live-cnn-toggle"
            checked={liveCnn}
            onChange={onLiveCnnToggle}
          />
          Live TF.js Inference (Feature C CNN)
        </label>
      </div>

      <div className="controls-group">
        <button
          className={`control-btn ${isRunning ? 'secondary' : 'primary'}`}
          onClick={isRunning ? onPause : onStart}
          disabled={experimentPhase === 'done' && !isRunning}
        >
          {isRunning ? 'Pause' : 'Start Experiment'}
        </button>
        
        {!isRunning && experimentPhase !== 'idle' && (
          <button className="control-btn" onClick={onReset}>
            Reset
          </button>
        )}
        
        {experimentPhase === 'gps' && (
          <button 
            className="control-btn warning"
            onClick={onToggleGps}
          >
            TURN OFF GPS
          </button>
        )}
        
        {experimentPhase === 'outage' && (
          <button className="control-btn secondary" onClick={onReset}>
            End Experiment
          </button>
        )}
      </div>
    </div>
  );
}