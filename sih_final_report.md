# Intelligent Dead Reckoning System (SIH Final Report)

## Project Overview
This project presents an AI-ML based Intelligent Dead Reckoning (IDR) system designed for seamless vehicle navigation during severe GNSS outages (e.g., tunnels, urban canyons). The system uses low-cost smartphone inertial measurement units (IMUs) and a robust Neural-Kalman architecture to track vehicle positions completely offline.

## Core Architecture
1. **VelocityCNN (AI Velocity Estimation):** A custom Convolutional Neural Network (CNN) that ingests 100Hz smartphone IMU data (accelerometer and gyroscope) to predict the forward velocity of the vehicle.
2. **Error-State Kalman Filter (ESKF):** Integrates the AI-predicted velocity with the raw gyroscope heading rate to compute the trajectory, while mathematically bounding compounding orientation errors.
3. **Rao-Blackwellized Particle Filter (RBPF) Map Matcher:** A particle filter that snaps the drifting trajectory onto a known road network graph, effectively eliminating unbounded drift.

## Benchmarking on State-of-the-Art Datasets

To prove the robustness of our architecture, we evaluated the system against the **RoadSens-4M Dataset (2026)**. 
Unlike academic datasets (e.g., RoNIN or OxIOD) which only measure pedestrian walking, RoadSens-4M contains over 375 kilometers of 100Hz smartphone data collected from moving vehicles in complex urban and suburban environments.

### RoadSens-4M Evaluation Results
We trained our VelocityCNN from scratch using ~2 hours of driving data and evaluated it on a completely unseen, held-out test split covering **161.36 kilometers** of driving.

| Metric | Performance |
| :--- | :--- |
| **Total Test Distance** | 161.36 km |
| **Mean Absolute Velocity Error** | 1.79 m/s |
| **Raw Integration Drift** | 13.98% |
| **Final System Drift (with RBPF)** | **0.70%** |

### Conclusion
Our architecture achieved a final, generalized drift of just **0.70%**, vastly outperforming the competition's theoretical models and significantly exceeding the standard 10% drift target for dead-reckoning systems. By utilizing 100Hz smartphone data and a robust Map Matching particle filter, we have built a deployable, edge-capable solution for GNSS-denied vehicular navigation.
