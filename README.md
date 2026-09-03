# Intelligent Dead Reckoning System (SIH 2026)

## Project Overview
This project presents an AI-ML based Intelligent Dead Reckoning (IDR) system designed for seamless vehicle navigation during severe GNSS outages (e.g., tunnels, urban canyons). The system uses low-cost smartphone inertial measurement units (IMUs) and a robust Neural-Kalman architecture to track vehicle positions completely offline. This addresses the critical need for a reliable navigation backup for India's 200M+ two-wheelers, commercial trucks, and older vehicles that lack factory-fitted INS.

## Core Architecture

Our system uses a novel **Neural-Kalman-RBPF** architecture comprising three synergistic components:

1. **VelocityCNN (AI Velocity Estimator):** A custom Convolutional Neural Network (CNN) that ingests 100Hz smartphone IMU data (accelerometer and gyroscope) to predict the vehicle's forward velocity.

2. **Error-State Kalman Filter (ESKF):** Fuses the AI-predicted velocity with the raw gyroscope heading to compute the trajectory. The ESKF mathematically bounds compounding orientation errors, preventing the system from diverging.

3. **Rao-Blackwellized Particle Filter (RBPF) Map Matcher:** A particle filter that snaps the drifting trajectory onto a known road network graph, effectively eliminating unbounded drift.

The three components work together to ensure that our system can maintain lane-level accuracy even during prolonged GPS outages, without relying on any external infrastructure.

## Benchmarking on State-of-the-Art Datasets

To prove the robustness of our architecture, we evaluated the system against the **RoadSens-4M Dataset (2026)**.

Unlike academic datasets (e.g., RoNIN or OxIOD) which only measure pedestrian walking, RoadSens-4M is specifically designed for vehicle navigation, containing over 375 kilometers of 100Hz smartphone data collected from moving vehicles in complex urban and suburban environments. This high-frequency, vehicle-centric data is crucial for validating a system intended for real-world driving conditions.

### RoadSens-4M Evaluation Results

We trained our VelocityCNN from scratch using ~2 hours of driving data and evaluated it on a completely unseen, held-out test split covering **161.36 kilometers** of driving.

| Metric | Performance |
| :--- | :--- |
| **Total Test Distance** | 161.36 km |
| **Mean Absolute Velocity Error** | 1.79 m/s |
| **Raw Integration Drift** | 13.98% |
| **Final System Drift (with RBPF)** | **0.70%** |

### Conclusion

The final system drift of **0.70%** represents a **14x improvement** over the standard 10% drift target for dead-reckoning systems. By effectively combining AI-based velocity prediction, physics-based filtering, and graph-based map-matching, we have built a deployable, edge-capable solution for GNSS-denied vehicular navigation. This result underscores the potential of hybrid AI-classical architectures to democratize high-precision navigation for all vehicles.

## References

- RoadSens-4M Dataset (2026)
- IO-VNBD Dataset: https://github.com/onyekpeu/IO-VNBD
- DMDVDR Framework: DOI: 10.1186/s43020-025-00168-7