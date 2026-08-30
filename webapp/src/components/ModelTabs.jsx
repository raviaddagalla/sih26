import React from 'react';
import ModelTab from './ModelTab';

const MODEL_IDS = [
  "cnn_baseline",
  "cnn_feature_c", 
  "gru",
  "tcn",
  "xgboost"
];

const LOW_SPEED_MODEL_ID = "cnn_feature_c_lowspeed";

/**
 * Tabs for viewing individual model details or comparison view
 */
export default function ModelTabs({
  activeTab,
  onTabChange,
  modelSnapshots,
  tripRefLat,
  tripRefLon,
  experimentPhase,
  outageStartIndex,
  outageDuration,
  benchmarkData,
  selectedTrip
}) {
  const tabs = [
    { id: 'compare', label: 'Compare All' },
    { id: 'cnn_baseline', label: 'CNN Baseline' },
    { id: 'cnn_feature_c', label: 'Feature C CNN' },
    { id: 'gru', label: 'GRU' },
    { id: 'tcn', label: 'TCN' },
    { id: 'xgboost', label: 'XGBoost' }
  ];

  return (
    <div className="tabs-container">
      <div className="tabs">
        {tabs.map(tab => (
          <button
            key={tab.id}
            className={`tab-btn ${activeTab === tab.id ? 'active' : ''}`}
            onClick={() => onTabChange(tab.id)}
            disabled={tab.id !== 'compare' && experimentPhase === 'idle'}
          >
            {tab.label}
          </button>
        ))}
      </div>
      
      {activeTab === 'compare' && (
        <ComparisonView 
          modelSnapshots={modelSnapshots}
          benchmarkData={benchmarkData}
          selectedTrip={selectedTrip}
        />
      )}
      
      {activeTab !== 'compare' && (
        <ModelTab
          modelId={activeTab}
          snapshot={modelSnapshots[activeTab]}
          tripRefLat={tripRefLat}
          tripRefLon={tripRefLon}
          experimentPhase={experimentPhase}
          outageStartIndex={outageStartIndex}
          outageDuration={outageDuration}
          benchmarkData={benchmarkData}
          selectedTrip={selectedTrip}
        />
      )}
    </div>
  );
}

/**
 * Comparison view showing all models side-by-side
 */
function ComparisonView({ modelSnapshots, benchmarkData, selectedTrip }) {
  if (!modelSnapshots) return null;
  
  // Get metrics summary for the selected trip
  const tripMetrics = benchmarkData?.metricsSummary || {};
  
  return (
    <div className="comparison-view">
      <h2>Model Comparison</h2>
      
      {/* Comparison table */}
      <div className="comparison-table">
        <div className="table-header">
          <div className="th">Model</div>
          <div className="th">Val RMSE (km/h)</div>
          <div className="th">Test RMSE (km/h)</div>
          <div className="th">Low-Speed RMSE (km/h)</div>
          <div className="th">Final Error (m)</div>
          <div className="th">Dist. (m)</div>
          <div className="th">Max Error (m)</div>
          <div className="th">Avg Error (m)</div>
          <div className="th">Drift (%)</div>
          <div className="th">Status</div>
        </div>
        <div className="table-body">
          {MODEL_IDS.map(modelId => {
            const snapshot = modelSnapshots[modelId];
            const metrics = tripMetrics[modelId] || {};
            const dr = metrics.dr?.[selectedTrip] || {};
            
            return (
              <div className="table-row" key={modelId}>
                <div className="td">
                  <strong>{snapshot?.name || modelId}</strong>
                  {snapshot?.usesLiveInference && <span className="badge live">LIVE</span>}
                </div>
                <div className="td">{metrics.valRmseKmh?.toFixed(2) ?? '-'}</div>
                <div className="td">{metrics.testRmseKmh?.toFixed(2) ?? '-'}</div>
                <div className="td">
                  {/* Low-speed regime (0-2 m/s) */}
                  {metrics.valRegimes?.[modelId]?.['0-2']?.rmse_kmh?.toFixed(2) ?? '-'}
                </div>
                <div className="td">
                  {snapshot?.finalPositionErrorM !== undefined 
                    ? snapshot.finalPositionErrorM.toFixed(1) 
                    : dr.final_position_error_m?.toFixed(1) ?? '-'}
                </div>
                <div className="td">
                  {snapshot?.distanceTraveled !== undefined 
                    ? snapshot.distanceTraveled.toFixed(1) 
                    : dr.reference_distance_m?.toFixed(1) ?? '-'}
                </div>
                <div className="td">
                  {snapshot?.maxPositionErrorM !== undefined 
                    ? snapshot.maxPositionErrorM.toFixed(1) 
                    : dr.max_position_error_m?.toFixed(1) ?? '-'}
                </div>
                <div className="td">
                  {snapshot?.avgPositionErrorM !== undefined 
                    ? snapshot.avgPositionErrorM.toFixed(1) 
                    : dr.mean_position_error_m?.toFixed(1) ?? '-'}
                </div>
                <div className="td">
                  {dr.drift_pct !== undefined 
                    ? dr.drift_pct.toFixed(2) + '%' 
                    : '-'}
                </div>
                <div className="td">
                  {snapshot?.usesLiveInference 
                    ? <span className="status live">Live TF.js</span>
                    : <span className="status replay">Offline Replay</span>}
                </div>
              </div>
            );
          })}
          
          {/* Low-speed experiment model */}
          {modelSnapshots[LOW_SPEED_MODEL_ID] && (
            <div className="table-row lowspeed-exp">
              <div className="td">
                <strong>{modelSnapshots[LOW_SPEED_MODEL_ID].name}</strong>
                <span className="badge experiment">(Experiment)</span>
              </div>
              <div className="td">{LOW_SPEED_MODEL_ID in benchmarkData.metricsSummary 
                ? benchmarkData.metricsSummary[LOW_SPEED_MODEL_ID].valRmseKmh?.toFixed(2) 
                : '-'
              }</div>
              <div className="td">{LOW_SPEED_MODEL_ID in benchmarkData.metricsSummary 
                ? benchmarkData.metricsSummary[LOW_SPEED_MODEL_ID].testRmseKmh?.toFixed(2) 
                : '-'
              }</div>
              <div className="td">{LOW_SPEED_MODEL_ID in benchmarkData.metricsSummary 
                ? benchmarkData.metricsSummary[LOW_SPEED_MODEL_ID].valRegimes?.[LOW_SPEED_MODEL_ID]?.['0-2']?.rmse_kmh?.toFixed(2) 
                : '-'
              }</div>
              <div className="td">
                {modelSnapshots[LOW_SPEED_MODEL_ID]?.finalPositionErrorM?.toFixed(1) ?? '-'}
              </div>
              <div className="td">
                {modelSnapshots[LOW_SPEED_MODEL_ID]?.maxPositionErrorM?.toFixed(1) ?? '-'}
              </div>
              <div className="td">
                {modelSnapshots[LOW_SPEED_MODEL_ID]?.avgPositionErrorM?.toFixed(1) ?? '-'}
              </div>
              <div className="td">-</div>
              <div className="td"><span className="status replay">Offline Replay</span></div>
            </div>
          )}
        </div>
      </div>
      
      {/* Best model badges */}
      <div className="badges">
        <div className="badge best">BEST VELOCITY: {getBestModel(tripMetrics, 'valRmseKmh', true)}</div>
        <div className="badge best">BEST LOW-SPEED: {getBestLowSpeedModel(tripMetrics)}</div>
        <div className="badge best">BEST DEAD RECKONING: {getBestDrModel(modelSnapshots, tripMetrics, selectedTrip)}</div>
      </div>
    </div>
  );
}

function getBestModel(metrics, key, ascending = true) {
  if (!metrics) return '-';
  let bestId = null;
  let bestValue = ascending ? Infinity : -Infinity;
  
  for (const [modelId, m] of Object.entries(metrics)) {
    const value = m[key];
    if (value === null || value === undefined) continue;
    if (ascending ? value < bestValue : value > bestValue) {
      bestValue = value;
      bestId = modelId;
    }
  }
  
  return bestId ? 
    (bestId === 'cnn_baseline' ? 'CNN Baseline' :
     bestId === 'cnn_feature_c' ? 'Feature C CNN' :
     bestId === 'gru' ? 'GRU' :
     bestId === 'tcn' ? 'TCN' :
     bestId === 'xgboost' ? 'XGBoost' : bestId) 
    : '-';
}

function getBestLowSpeedModel(metrics) {
  if (!metrics) return '-';
  let bestId = null;
  let bestValue = Infinity;
  
  for (const [modelId, m] of Object.entries(metrics)) {
    const lowSpeedRmse = m.valRegimes?.[modelId]?.['0-2']?.rmse_kmh;
    if (lowSpeedRmse === null || lowSpeedRmse === undefined) continue;
    if (lowSpeedRmse < bestValue) {
      bestValue = lowSpeedRmse;
      bestId = modelId;
    }
  }
  
  return bestId ? 
    (bestId === 'cnn_baseline' ? 'CNN Baseline' :
     bestId === 'cnn_feature_c' ? 'Feature C CNN' :
     bestId === 'gru' ? 'GRU' :
     bestId === 'tcn' ? 'TCN' :
     bestId === 'xgboost' ? 'XGBoost' : bestId) 
    : '-';
}

function getBestDrModel(modelSnapshots, tripMetrics, selectedTrip) {
  if (!modelSnapshots || !tripMetrics) return '-';
  let bestId = null;
  let bestError = Infinity;
  
  for (const [modelId, snapshot] of Object.entries(modelSnapshots)) {
    const error = snapshot?.finalPositionErrorM ?? 
                  (tripMetrics[modelId]?.dr?.[selectedTrip]?.final_position_error_m ?? Infinity);
    if (error < bestError) {
      bestError = error;
      bestId = modelId;
    }
  }
  
  return bestId ? 
    (bestId === 'cnn_baseline' ? 'CNN Baseline' :
     bestId === 'cnn_feature_c' ? 'Feature C CNN' :
     bestId === 'gru' ? 'GRU' :
     bestId === 'tcn' ? 'TCN' :
     bestId === 'xgboost' ? 'XGBoost' : bestId) 
    : '-';
}