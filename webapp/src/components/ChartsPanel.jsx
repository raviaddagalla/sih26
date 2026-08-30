import React from 'react';

/**
 * Charts panel for experiment comparison
 */
export default function ChartsPanel({
  modelSnapshots,
  benchmarkData,
  selectedTrip,
  experimentPhase,
  outageStartIndex,
  outageDuration
}) {
  if (!modelSnapshots) return null;

  const tripRefLat = benchmarkData.trips[selectedTrip]?.ref?.lat;
  const tripRefLon = benchmarkData.trips[selectedTrip]?.ref?.lon;
  
  return (
    <div className="charts-panel">
      <h2>Experiment Charts</h2>
      
<div className="chart-tabs">
          <button className="tab-btn active" onClick={() => {/* handled by parent */}}>
            Position Error vs Time
          </button>
          <button className="tab-btn" onClick={() => {/* handled by parent */}}>
            Velocity Comparison
          </button>
          <button className="tab-btn" onClick={() => {/* handled by parent */}}>
            Heading Comparison
          </button>
        </div>
        
        {/* Chart Legend */}
        <div className="chart-legend">
          {Object.entries(modelSnapshots).map(([modelId, snapshot]) => {
            if (!snapshot) return null;
            return (
              <div key={modelId} className="legend-item">
                <span className="legend-color" style={{backgroundColor: snapshot.color || MODEL_COLORS[modelId] || '#95a5a6'}}></span>
                <span className="legend-label">{snapshot.name || modelId}</span>
                {snapshot.usesLiveInference && <span className="badge live">LIVE</span>}
                {modelId === LOW_SPEED_MODEL_ID && <span className="badge experiment">EXP</span>}
              </div>
            );
          })}
        </div>
       
       {/* Position Error Chart */}
      <div className="chart-container">
        <h3>Position Error vs Outage Time</h3>
        <div className="chart-wrapper">
          <svg className="error-time-chart" viewBox="0 0 620 220" preserveAspectRatio="xMidYMid meet">
            {/* Axes */}
            <line x1="60" y1="20" x2="60" y2="180" stroke="#ccc" strokeWidth="1"/>
            <line x1="60" y1="180" x2="560" y2="180" stroke="#ccc" strokeWidth="1"/>
            {/* Y-axis labels */}
            <text x="20" y="90" textAnchor="end" fill="#666" fontSize="10">0m</text>
            <text x="20" y="50" textAnchor="end" fill="#666" fontSize="10">10m</text>
            <text x="20" y="80" textAnchor="end" fill="#666" fontSize="10">20m</text>
            {/* X-axis labels (time in seconds) */}
            {[0, 15, 30, 45, 60].map(sec => {
              const x = 60 + (sec / 60) * 500;
              return (
                <>
                  <line key={`tick-${x}`} x1={x} y1="180" x2={x} y2="184" stroke="#ccc" strokeWidth="1"/>
                  <text key={`label-${x}`} x={x} y="200" textAnchor="middle" fill="#666" fontSize="10">{sec}s</text>
                </>
              );
            })}
            {/* Model error lines */}
            {MODEL_IDS.map((modelId, idx) => {
              const snapshot = modelSnapshots[modelId];
              if (!snapshot || !snapshot.positionErrorHistory || snapshot.positionErrorHistory.length === 0) return null;
              
              const color = snapshot.color || MODEL_COLORS[modelId] || '#95a5a6';
              return (
                <polyline 
                  key={`error-${modelId}`}
                  fill="none"
                  stroke={color}
                  strokeWidth="2"
points={snapshot.positionErrorHistory.map((e, i) => {
                     const x = 60 + (i / Math.max(1, snapshot.positionErrorHistory.length - 1)) * 500;
                     const y = 180 - (e / 20) * 160; // scale 0-20m to 160px
                     return `${x},${y}`;
                   }).join(' ')}
                />
              );
            })}
            
            {/* Low-speed experiment model */}
            {modelSnapshots[LOW_SPEED_MODEL_ID] && modelSnapshots[LOW_SPEED_MODEL_ID].positionErrorHistory && (
              <polyline 
                key={`error-${LOW_SPEED_MODEL_ID}`}
                fill="none"
                stroke={modelSnapshots[LOW_SPEED_MODEL_ID].color || '#dda0dd'}
                strokeWidth="2"
points={modelSnapshots[LOW_SPEED_MODEL_ID].positionErrorHistory.map((e, i) => {
                   const x = 60 + (i / Math.max(1, modelSnapshots[LOW_SPEED_MODEL_ID].positionErrorHistory.length - 1)) * 500;
                   const y = 180 - (e / 20) * 160;
                   return `${x},${y}`;
                 }).join(' ')}
              />
            )}
          </svg>
        </div>
      </div>
      
      {/* Velocity Comparison Chart */}
      <div className="chart-container">
        <h3>Velocity Comparison (km/h)</h3>
        <div className="chart-wrapper">
          <svg className="velocity-chart" viewBox="0 0 620 220" preserveAspectRatio="xMidYMid meet">
            {/* Axes */}
            <line x1="60" y1="20" x2="60" y2="180" stroke="#ccc" strokeWidth="1"/>
            <line x1="60" y1="180" x2="560" y2="180" stroke="#ccc" strokeWidth="1"/>
{/* Y-axis labels - up to 120 km/h */}
                      {[0, 30, 60, 90, 120].forEach(vel => {
                        const y = 180 - (vel / 120) * 160;
                        return (
                          <>
                            <line key={`v-tick-${y}`} x1="60" y1={y} x2="56" y2={y} stroke="#ccc" strokeWidth="1"/>
                            <text key={`v-label-${y}`} x="50" y={y+4} textAnchor="end" fill="#666" fontSize="10">{vel}</text>
                          </>
                        );
                      })}
{/* Reference velocity line */}
             {tripRefLat && tripRefLon && benchmarkData.trips[selectedTrip]?.ref?.vel && 
               benchmarkData.trips[selectedTrip]?.ref?.vel.length > outageStartIndex && (
                 <polyline 
                   className="ref-velocity"
                   fill="none"
                   stroke="#3498db"
                   strokeWidth="2"
                   points={benchmarkData.trips[selectedTrip].ref.vel
                             .slice(outageStartIndex, outageStartIndex + outageDuration)
                             .map((v, i) => {
                               const x = 60 + (i / Math.max(1, outageDuration - 1)) * 500;
                               const y = 180 - ((v * 3.6) / 120) * 160;
                               return `${x},${y}`;
                             }).join(' ')}
                 />
               )}
            {/* Model velocity lines */}
            {MODEL_IDS.map((modelId, idx) => {
              const snapshot = modelSnapshots[modelId];
              if (!snapshot || !snapshot.velocityHistory || snapshot.velocityHistory.length === 0) return null;
              
              const color = snapshot.color || MODEL_COLORS[modelId] || '#95a5a6';
              return (
                <polyline 
                  key={`vel-${modelId}`}
                  fill="none"
                  stroke={color}
                  strokeWidth="2"
points={snapshot.velocityHistory
                             .slice(0, Math.min(snapshot.velocityHistory.length, outageDuration))
                             .map((v, i) => {
                               const x = 60 + (i / Math.max(1, outageDuration - 1)) * 500;
                               const y = 180 - ((v * 3.6) / 120) * 160;
                               return `${x},${y}`;
                             }).join(' ')}
                />
              );
            })}
            
            {/* Low-speed experiment model */}
            {modelSnapshots[LOW_SPEED_MODEL_ID] && modelSnapshots[LOW_SPEED_MODEL_ID].velocityHistory && (
              <polyline 
                key={`vel-${LOW_SPEED_MODEL_ID}`}
                fill="none"
                stroke={modelSnapshots[LOW_SPEED_MODEL_ID].color || '#dda0dd'}
                strokeWidth="2"
points={modelSnapshots[LOW_SPEED_MODEL_ID].velocityHistory
                           .slice(0, Math.min(modelSnapshots[LOW_SPEED_MODEL_ID].velocityHistory.length, outageDuration))
                           .map((v, i) => {
                             const x = 60 + (i / Math.max(1, outageDuration - 1)) * 500;
                             const y = 180 - ((v * 3.6) / 120) * 160;
                             return `${x},${y}`;
                           }).join(' ')}
              />
            )}
          </svg>
        </div>
      </div>
      
      {/* Heading Comparison Chart */}
      <div className="chart-container">
        <h3>Heading Comparison (°)</h3>
        <div className="chart-wrapper">
          <svg className="heading-chart" viewBox="0 0 620 220" preserveAspectRatio="xMidYMid meet">
            {/* Axes */}
            <line x1="60" y1="20" x2="60" y2="180" stroke="#ccc" strokeWidth="1"/>
            <line x1="60" y1="180" x2="560" y2="180" stroke="#ccc" strokeWidth="1"/>
            {/* Y-axis labels - -180 to +180 degrees */}
            {[-180, -90, 0, 90, 180].forEach(angle => {
              const y = 180 - ((angle + 180) / 360) * 160;
              return (
                <>
                  <line key={`h-tick-${y}`} x1="60" y1={y} x2="56" y2={y} stroke="#ccc" strokeWidth="1"/>
                  <text key={`h-label-${y}`} x="50" y={y+4} textAnchor="end" fill="#666" fontSize="10">{angle}°</text>
                </>
              );
            })}
            {/* Reference heading line (if available) */}
            {/* Model heading lines - all models should have same heading since they share gyro input */}
            {MODEL_IDS.map((modelId, idx) => {
              const snapshot = modelSnapshots[modelId];
              if (!snapshot || !snapshot.headingHistory || snapshot.headingHistory.length === 0) return null;
              
              const color = snapshot.color || MODEL_COLORS[modelId] || '#95a5a6';
              return (
                <polyline 
                  key={`heading-${modelId}`}
                  fill="none"
                  stroke={color}
                  strokeWidth="2"
points={snapshot.headingHistory
                             .slice(0, Math.min(snapshot.headingHistory.length, outageDuration))
                             .map((h, i) => {
                               const x = 60 + (i / Math.max(1, outageDuration - 1)) * 500;
                               const y = 180 - ((h + 180) / 360) * 160;
                               return `${x},${y}`;
                             }).join(' ')}
                />
              );
            })}
            
            {/* Low-speed experiment model */}
            {modelSnapshots[LOW_SPEED_MODEL_ID] && modelSnapshots[LOW_SPEED_MODEL_ID].headingHistory && (
              <polyline 
                key={`heading-${LOW_SPEED_MODEL_ID}`}
                fill="none"
                stroke={modelSnapshots[LOW_SPEED_MODEL_ID].color || '#dda0dd'}
                strokeWidth="2"
points={modelSnapshots[LOW_SPEED_MODEL_ID].headingHistory
                           .slice(0, Math.min(modelSnapshots[LOW_SPEED_MODEL_ID].headingHistory.length, outageDuration))
                           .map((h, i) => {
                             const x = 60 + (i / Math.max(1, outageDuration - 1)) * 500;
                             const y = 180 - ((h + 180) / 360) * 160;
                             return `${x},${y}`;
                           }).join(' ')}
              />
            )}
          </svg>
        </div>
      </div>
    </div>
  );
}

// Helper constants
const MODEL_IDS = [
  "cnn_baseline",
  "cnn_feature_c", 
  "gru",
  "tcn",
  "xgboost"
];

const MODEL_COLORS = {
  "cnn_baseline": "#ff6b6b",
  "cnn_feature_c": "#4ecdc4", 
  "gru": "#45b7d1",
  "tcn": "#96ceb4",
  "xgboost": "#ffeaa7"
};

const LOW_SPEED_MODEL_ID = "cnn_feature_c_lowspeed";