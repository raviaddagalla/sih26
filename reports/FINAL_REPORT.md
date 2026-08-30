# Velocity Prediction & Dead Reckoning Report

## Project Overview
Developed a set of velocity prediction models to enable robust dead reckoning (DR) during GNSS outages. The system uses IMU data (linear acceleration and gyroscope) to estimate vehicle velocity, which is then integrated with yaw rate to track position.

## Model Shootout
Five baseline models were evaluated on a trip-disjoint split (Val: Vfa02, Y1; Test: A5, T2).

| Model | Val RMSE (km/h) | Test RMSE (km/h) | DR A5 Final Err (m) | DR T2 Final Err (m) |
| :--- | :---: | :---: | :---: | :---: |
| cnn_baseline | 28.27 | 66.91 | 1422.2 | 732.4 |
| **cnn_feature_c** | **20.96** | 51.88 | 334.6 | 475.1 |
| gru | 27.22 | 68.21 | 186.3 | 623.0 |
| tcn | 29.13 | 49.85 | 886.4 | 464.5 |
| xgboost | 21.71 | 53.47 | 454.5 | 511.7 |

**Best Model:** `cnn_feature_c` provided the best balance of overall validation accuracy and DR stability.

## Analysis of Failure Modes
### The Low-Speed Blind Spot (Problem 2)
A critical failure mode was identified across all models: **over-prediction of velocity at near-zero speeds**.
- **0-2 m/s Regime:** Validation bias was typically **-8.5 to -10.1 m/s**, meaning models predicted ~30 km/h while the vehicle was stopped.
- **Impact:** This leads to significant "phantom" drift in DR during stationary periods. The A5 benchmark outage landed on a near-stationary segment, amplifying this error.

## Controlled Experiment: Low-Speed Weighted Loss
To address the blind spot, a weighted MSE loss was implemented for `cnn_feature_c_lowspeed`, penalizing low-velocity errors more heavily.

**Results (Validation Regimes):**
- **0-2 m/s:** RMSE 33.1 $\rightarrow$ 25.0 km/h | Bias -8.77 $\rightarrow$ -6.32 m/s ($\checkmark$ Improved)
- **10+ m/s:** RMSE 19.4 $\rightarrow$ 23.1 km/h | Bias +2.91 $\rightarrow$ +4.05 m/s ($\times$ Degraded)
- **DR A5 Final Error:** 334.6 m $\rightarrow$ 255.8 m ($\checkmark$ Improved)

**Conclusion:** The weighted loss successfully reduced the low-speed bias, improving DR accuracy on stationary segments, but at the cost of slight degradation in high-speed accuracy.

## Deliverables Summary
- **Model Registry:** `model_registry.json` containing all 6 model versions.
- **Benchmarks:** `reports/metrics.json` and detailed trajectory CSVs.
- **Webapp:** A Vite/React application deploying the best model (`cnn_feature_c`) via TensorFlow.js for real-time DR visualization.
- **Checkpoints:** Versioned PyTorch weights for all models.
