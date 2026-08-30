import React from 'react';

/**
 * Application header with title and status indicators
 */
export default function Header({ 
  gpsActive, 
  experimentPhase, 
  modelLoadStatus, 
  liveModelVerified 
}) {
  const statusText = gpsActive 
    ? 'GPS ACTIVE' 
    : experimentPhase === 'outage' 
      ? 'GPS BLACKOUT (INS MODE)' 
      : 'IDLE';

  const statusClass = gpsActive 
    ? 'active' 
    : experimentPhase === 'outage' 
      ? 'blackout' 
      : 'idle';

  const phaseBadgeClass = experimentPhase === 'outage' ? 'outage' 
    : experimentPhase === 'gps' ? 'gps' 
    : experimentPhase === 'done' ? 'done' 
    : 'idle';

  return (
    <header className="app-header">
      <div className="header-content">
        <h1>
          <span className="logo-icon">▲</span> GNSS-Denied Vehicle Localization
        </h1>
        <div className="status-bar">
          <div className={`status-indicator ${statusClass}`}></div>
          <div className="status-text">{statusText}</div>
          <span className={`experiment-phase-badge ${phaseBadgeClass}`}>
            {experimentPhase.toUpperCase()}
          </span>
          
          {modelLoadStatus !== 'idle' && (
            <div className="model-status">
              <span className="model-status-dot">
                {modelLoadStatus === 'ready' 
                  ? (liveModelVerified ? '✓ verified' : '⚠ loading') 
                  : modelLoadStatus === 'error' 
                    ? '✗ error' 
                    : '○ loading'}
              </span>
              <span className="model-status-text">
                {modelLoadStatus === 'ready' 
                  ? 'Live Model Ready' 
                  : modelLoadStatus === 'error' 
                    ? 'Live Model Error' 
                    : 'Loading Live Model...'}
              </span>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}