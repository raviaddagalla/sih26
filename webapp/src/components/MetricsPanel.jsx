import React from 'react';

/**
 * Metrics panel showing final results table
 */
export default function MetricsPanel({
  modelSnapshots,
  benchmarkData,
  selectedTrip,
  experimentPhase
}) {
  if (experimentPhase !== 'done' || !modelSnapshots) return null;
  
  const metrics = benchmarkData?.metricsSummary || {};
  const naiveBaselineMs = benchmarkData?.naiveTrainMeanMs || 0;
  
  return (
    <div className="metrics-panel">
      <h2>Final Results (Experiment Complete)</h2>
      
      <div className="metrics-summary">
        <p>
          Naive baseline (training set mean): {naiveBaselineMs.toFixed(1)} m/s 
          ({(naiveBaselineMs * 3.6).toFixed(1)} km/h)
        </p>
      </div>
      
      <div className="results-table">
        <div className="table-header">
          <div className="th">Model</div>
          <div className="th">Val RMSE (km/h)</div>
          <div className="th">Test RMSE (km/h)</div>
          <div className="th">0-2 m/s RMSE (km/h)</div>
          <div className="th">Final Error (m)</div>
          <div className="th">Dist. (m)</div>
          <div className="th">Max Error (m)</div>
          <div className="th">Avg Error (m)</div>
          <div className="th">Drift (%)</div>
          <div className="th">Improvement vs Naive (%)</div>
        </div>
        <div className="table-body">
          {MODEL_IDS.map(modelId => {
            const snapshot = modelSnapshots[modelId];
            const m = metrics[modelId] || {};
            const dr = m.dr?.[selectedTrip] || {};
            
            // Calculate improvement over naive
            const testRmse = m.testRmseKmh || 0;
            const naiveImprovement = testRmse > 0 
              ? ((naiveBaselineMs - testRmse) / naiveBaselineMs) * 100 
              : 0;
            
            return (
              <div className="table-row" key={modelId}>
                <div className="td">
                  <strong>{getModelName(modelId)}</strong>
                  {snapshot?.usesLiveInference && <span className="badge live">LIVE</span>}
                </div>
                <div className="td">{m.valRmseKmh?.toFixed(2) ?? '-'}</div>
                <div className="td">{m.testRmseKmh?.toFixed(2) ?? '-'}</div>
                <div className="td">
                  {m.valRegimes?.[modelId]?.['0-2']?.rmse_kmh?.toFixed(2) ?? '-'}
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
                   {naiveImprovement >= 0 
                     ? <span className="positive">+{naiveImprovement.toFixed(1)}%</span>
                     : <span className="negative">{naiveImprovement.toFixed(1)}%</span>}
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
              <div className="td">
                {LOW_SPEED_MODEL_ID in metrics 
                  ? metrics[LOW_SPEED_MODEL_ID].valRmseKmh?.toFixed(2) 
                  : '-'
                }
              </div>
              <div className="td">
                {LOW_SPEED_MODEL_ID in metrics 
                  ? metrics[LOW_SPEED_MODEL_ID].testRmseKmh?.toFixed(2) 
                  : '-'
                }
              </div>
              <div className="td">
                {LOW_SPEED_MODEL_ID in metrics 
                  ? metrics[LOW_SPEED_MODEL_ID].valRegimes?.[LOW_SPEED_MODEL_ID]?.['0-2']?.rmse_kmh?.toFixed(2) 
                  : '-'
                }
              </div>
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
<div className="td">
  {LOW_SPEED_MODEL_ID in metrics 
    ? (() => {
        const improvement = ((benchmarkData?.naiveTrainMeanMs || 0) - 
                           (metrics[LOW_SPEED_MODEL_ID].testRmseKmh || 0)) / 
                          (benchmarkData?.naiveTrainMeanMs || 1) * 100;
        return improvement >= 0 
          ? <span className="positive">+{improvement.toFixed(1)}%</span>
          : <span className="negative">{improvement.toFixed(1)}%</span>;
      })()
    : '-'
  }
</div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function getModelName(modelId) {
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

const MODEL_IDS = [
  "cnn_baseline",
  "cnn_feature_c", 
  "gru",
  "tcn",
  "xgboost"
];

const LOW_SPEED_MODEL_ID = "cnn_feature_c_lowspeed";