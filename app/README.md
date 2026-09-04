# Intelligent Dead Reckoning (IDR) Navigation App

A production-grade Android Flutter application featuring offline **Intelligent Dead Reckoning (IDR)** powered by on-device **TensorFlow Lite AI velocity estimation**, a **15-state Error-State Kalman Filter (ESKF)**, **Non-Holonomic Constraints (NHC)**, **adaptive GNSS outage handling**, **route map-matching**, and an interactive **Demo Mode** simulating real vehicular GNSS blackout segments.

---

## Key Features

1. **On-Device Deep Learning Inference**:
   - Ingests high-frequency 100 Hz phone IMU signals (3-axis accelerometer and 3-axis gyroscope) into an optimized rolling buffer.
   - Executes the pre-trained `VelocityCNN` model using `tflite_flutter` with the channels-first shape `[1, 6, 200]` (2.0-second window) to predict forward vehicle velocity with high precision.

2. **15-State Error-State Kalman Filter (ESKF)**:
   - Tracks vehicle position (East, North, Down), velocity vector, quaternion attitude, gyroscope biases, and accelerometer biases.
   - Fuses forward AI speed predictions with vehicle body kinematic constraints (Zero lateral slip $v_y \approx 0$ and Zero vertical bounce $v_z \approx 0$).
   - Automatic Zero Velocity Updates (ZUPT) when stationary.

3. **Dynamic Phone Mounting Alignment**:
   - Uses the Rodrigues rotation formula to extract the gravity vector and dynamically project arbitrary phone orientations (portrait, landscape, dash-mounted, angled) into the vehicle's reference frame.

4. **Adaptive GNSS Outage State Machine**:
   - Seamlessly switches states: `STRONG` $\to$ `DEGRADED` $\to$ `DENIED` (pure AI dead-reckoning) $\to$ `REACQUIRING`.
   - Sigmoid reacquisition blending eliminates coordinate snapping when exiting tunnels or underpasses.

5. **Turn-by-Turn Routing & Route Map-Matching**:
   - OpenStreetMap interactive vector tiles (`flutter_map`).
   - Nominatim search with live destination autocompletion.
   - OSRM driving route generation with polyline rendering, distance, and ETA.
   - Orthogonal map-matching that softly snaps the navigation state to the active route while allowing real route excursions.

6. **Interactive Demo Mode**:
   - Built-in 100 Hz vehicular replay dataset (`assets/demo/test_dataset.csv`, 12,000 rows / 120s) with an intentional 45-second GNSS blackout.
   - Interactive control panel: Play, Pause, Resume, Restart, and Speed multipliers ($1\times, 2\times, 5\times$).
   - Real-time Telemetry HUD showing GNSS state badge, navigation mode, speed km/h, AI speed, IMU frequency, and position uncertainty.

---

## Project Structure

```
lib/
├── adapters/
│   ├── sensor_data_source.dart      # Abstract sensor stream interface
│   ├── android_sensor_adapter.dart  # Live phone IMU & GNSS adapter
│   └── dataset_replay_adapter.dart  # 100 Hz CSV dataset replay adapter
├── idr_engine/
│   ├── core/
│   │   ├── math_utils.dart          # Vector3, Matrix3, Quaternion, WGS84/NED
│   │   ├── imu_sample.dart          # IMU sample representation
│   │   ├── gnss_sample.dart         # GNSS sample representation
│   │   └── nav_telemetry.dart       # 10 Hz navigation state stream
│   ├── calibration/
│   │   └── phone_alignment.dart     # Gravity extraction & Rodrigues alignment
│   ├── filtering/
│   │   └── imu_preprocessor.dart    # Low-pass filter, ZUPT, [1, 6, 200] tensor builder
│   ├── velocity/
│   │   └── velocity_cnn_service.dart # TFLite VelocityCNN inference service
│   ├── eskf/
│   │   └── eskf.dart                # 15-state Error-State Kalman Filter
│   ├── fusion/
│   │   └── gnss_state_machine.dart  # Outage FSM with Sigmoid reacquisition
│   ├── map_matching/
│   │   └── route_matcher.dart       # Soft polyline route projector
│   └── idr_engine.dart              # Master navigation coordinator
├── screens/
│   └── map_screen.dart              # Map view with live navigation & demo controls
├── widgets/
│   ├── demo_control_panel.dart      # Replay slider, speed buttons, play/pause
│   ├── telemetry_hud.dart           # Real-time state HUD
│   ├── navigation_panel.dart        # Route instructions & metrics
│   ├── search_bar.dart              # Address autocompletion search
│   └── location_picker.dart         # Destination picker modal
└── main.dart                        # Application bootstrap
```

---

## Automated Verification

The core IDR engine contains an automated test suite verifying all mathematical transformations, Kalman filter updates, outage transitions, and dataset parsing:

```bash
dart --enable-asserts test/run_idr_tests.dart
```

All 8 test suites execute with 0 errors:
- WGS84 Lat/Lon to NED and back round-trip consistency
- Quaternion rotation vector and rotation matrix
- ESKF nominal state and error covariance propagation
- ML Forward Velocity and NHC updates
- GNSS position update uncertainty reduction
- GNSS State Machine transitions during Outage and Reacquisition
- Route Matcher soft-snapping and excursion detection
- Dataset CSV parsing and row integrity
