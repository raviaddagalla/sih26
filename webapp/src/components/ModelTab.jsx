import React from 'react';

/**
 * Detailed view for a single model
 */
export default function ModelTab({
  modelId,
  snapshot,
  tripRefLat,
  tripRefLon,
  experimentPhase,
  outageStartIndex,
  outageDuration,
  benchmarkData,
  selectedTrip
}) {
  if (!snapshot) return <div>Loading model data...</div>;
  
  const metrics = benchmarkData?.metricsSummary[modelId] || {};
  const dr = metrics.dr?.[selectedTrip] || {};
  
  return (
    <div className="model-tab">
      <div className="model-header">
        <h2>{snapshot.name}</h2>
        <div className="model-meta">
          <span>Version: v1</span>
          <span>• Parameters: {snapshot?.usesLiveInference ? '~11K' : 'N/A (Replay)'}</span>
          <span>• Inference: {snapshot?.usesLiveInference ? 'Live TF.js' : 'Offline Replay'}</span>
        </div>
      </div>
      
      <div className="model-content">
        <div className="metric-group">
          <h3>Current Status</h3>
          <div className="metric-row">
            <span className="label">Phase:</span>
            <span className="value">{experimentPhase}</span>
          </div>
          <div className="metric-row">
            <span className="label">Outage Progress:</span>
            <span className="value">
              {experimentPhase === 'outage' 
                ? `In Progress (Max ${outageDuration}s)` 
                : '-'}
            </span>
          </div>
          <div className="metric-row">
            <span className="label">Position Error:</span>
            <span className="value">{snapshot.positionError.toFixed(1)} m</span>
          </div>
          <div className="metric-row">
            <span className="label">Max Error:</span>
            <span className="value">{snapshot.maxPositionError.toFixed(1)} m</span>
          </div>
          <div className="metric-row">
            <span className="label">Avg Error:</span>
            <span className="value">{snapshot.avgPositionError.toFixed(1)} m</span>
          </div>
          <div className="metric-row">
            <span className="label">Velocity:</span>
            <span className="value">
              {(snapshot.velocity * 3.6).toFixed(1)} km/h 
              ({snapshot.velocity.toFixed(2)} m/s)
            </span>
            {snapshot.zuptAssistActive && <span className="zupt-badge">[ZUPT]</span>}
          </div>
          <div className="metric-row">
            <span className="label">Heading:</span>
            <span className="value">{snapshot.heading.toFixed(1)}°</span>
          </div>
          <div className="metric-row">
            <span className="label">Distance Traveled:</span>
            <span className="value">{snapshot.distanceTraveled.toFixed(1)} m</span>
          </div>
          <div className="metric-row">
            <span className="label">Drift:</span>
            <span className="value">
              {snapshot.distanceTraveled > 5 
                ? ((snapshot.positionError / snapshot.distanceTraveled) * 100).toFixed(2) + '%' 
                : 'N/A (insufficient distance)'}
            </span>
          </div>
        </div>
        
        <div className="metric-group">
          <h3>Benchmark Metrics (Offline)</h3>
          <div className="metric-row">
            <span className="label">Val RMSE:</span>
            <span className="value">{metrics.valRmseKmh?.toFixed(2) ?? '-'} km/h</span>
          </div>
          <div className="metric-row">
            <span className="label">Test RMSE:</span>
            <span className="value">{metrics.testRmseKmh?.toFixed(2) ?? '-'} km/h</span>
          </div>
          <div className="metric-row">
            <span className="label">Test MAE:</span>
            <span className="value">{metrics.testMaeKmh?.toFixed(2) ?? '-'} km/h</span>
          </div>
          <div className="metric-row">
            <span className="label">0-2 m/s RMSE:</span>
            <span className="value">
              {metrics.valRegimes?.[modelId]?.['0-2']?.rmse_kmh?.toFixed(2) ?? '-'} km/h
            </span>
          </div>
          <div className="metric-row">
            <span className="label">2-5 m/s RMSE:</span>
            <span className="value">
              {metrics.valRegimes?.[modelId]?.['2-5']?.rmse_kmh?.toFixed(2) ?? '-'} km/h
            </span>
          </div>
          <div className="metric-row">
            <span className="label">5-10 m/s RMSE:</span>
            <span className="value">
              {metrics.valRegimes?.[modelId]?.['5-10']?.rmse_kmh?.toFixed(2) ?? '-'} km/h
            </span>
          </div>
          <div className="metric-row">
            <span className="label">10+ m/s RMSE:</span>
            <span className="value">
              {metrics.valRegimes?.[modelId]?.['10-inf']?.rmse_kmh?.toFixed(2) ?? '-'} km/h
            </span>
          </div>
        </div>
        
        <div className="metric-group">
          <h3>Live Charts</h3>
          <div className="chart-container">
            <div className="chart-title">Velocity (km/h)</div>
            <svg className="velocity-chart" width="100%" height="100">
              <line x1="40" y1="15" x2="40" y2="90" stroke="#ddd" strokeWidth="1"/>
              <line x1="40" y1="90" x2="260" y2="90" stroke="#ddd" strokeWidth="1"/>
              {/* Reference velocity */}
              {snapshot.refVelocityHistory.length > 0 && (
                <polyline 
                  points={snapshot.refVelocityHistory.map((v, i) => 
                    `${40 + i * (220 / Math.max(1, snapshot.refVelocityHistory.length - 1))}, ${90 - ((v * 3.6) / 80) * 80}`
                  ).join(' ')}
                  fill="none"
                  stroke="#3498db"
                  strokeWidth="2"
                />
              )}
              {/* Model velocity */}
              {snapshot.velocityHistory.length > 0 && (
                <polyline 
                  points={snapshot.velocityHistory.map((v, i) => 
                    `${40 + i * (220 / Math.max(1, snapshot.velocityHistory.length - 1))}, ${90 - ((v * 3.6) / 80) * 80}`
                  ).join(' ')}
                  fill="none"
                  stroke={snapshot.color}
                  strokeWidth="2"
                />
              )}
            </svg>
          </div>
          
          <div className="chart-container">
            <div className="chart-title">Position Error (m)</div>
            <svg className="error-chart" width="100%" height="100">
              <line x1="40" y1="15" x2="40" y2="90" stroke="#ddd" strokeWidth="1"/>
              <line x1="40" y1="90" x2="260" y2="90" stroke="#ddd" strokeWidth="1"/>
              {snapshot.positionErrorHistory.length > 0 && (
                <polyline 
                  points={snapshot.positionErrorHistory.map((e, i) => 
                    `${40 + i * (220 / Math.max(1, snapshot.positionErrorHistory.length - 1))}, ${90 - (e / 20) * 80}`
                  ).join(' ')}
                  fill="none"
                  stroke={snapshot.color}
                  strokeWidth="2"
                />
              )}
            </svg>
          </div>
          
          <div className="chart-container">
            <div className="chart-title">Heading Error (°)</div>
            <svg className="heading-chart" width="100%" height="100">
              <line x1="40" y1="15" x2="40" y2="90" stroke="#ddd" strokeWidth="1"/>
              <line x1="40" y1="90" x2="260" y2="90" stroke="#ddd" strokeWidth="1"/>
              {/* Heading error: model heading - reference heading */}
              {snapshot.headingHistory.length > 0 && snapshot.refVelocityHistory.length > 0 && (
                <polyline 
                  points="{snapshot.headingHistory.map((h, i) => {
                    const refH = snapshot.refHeadingHistory?.[i] ?? 0;
                    const diff = ((h - refH + 180) % 360) - 180; // shortest angular difference
                    return `${40 + i * (220 / Math.max(1, snapshot.headingHistory.length - 1))}, ${90 - (Math.abs(diff) / 30) * 80}`;
                  }).join(' ')}"
                  fill="none"
                  stroke={snapshot.color}
                  strokeWidth="2"
                />
              )}
            </svg>
          </div>
        </div>
      </div>
    </div>
  );
}