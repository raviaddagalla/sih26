# IDR Navigation App

A cross-platform Flutter prototype for the SIH Intelligent Dead Reckoning problem. It keeps navigation continuous through GNSS weakness or blackout by combining smartphone IMU signals with the recovered VelocityCNN model, and it includes a separate hackathon demo mode for repeatable GPS-off demonstrations.

## What is implemented

The app uses real on-device TensorFlow Lite inference from `assets/models/velocity_cnn.tflite`. It loads the recovered `cnn_feature_c_lowspeed` checkpoint converted to float32 TFLite, applies the training normalization from `assets/models/norm_params.json`, accepts 20-sample windows, and feeds accelerometer XYZ plus gyroscope yaw/pitch/roll in the exact six-channel order used by the model.

The production path reads live accelerometer and gyroscope streams, requests GNSS permission, consumes live position updates, and maintains a fusion engine that seeds and corrects the inertial position from GNSS whenever it is available. If GNSS is unavailable or weak, the navigation state switches to **AI DEAD RECKONING** and uses TFLite-predicted velocity plus heading to integrate position. The UI presents this as a map-first, vibrant navigation surface with blue route styling, floating controls, live telemetry, status chips, and a moving vehicle marker.

Demo mode is enabled by default for a hackathon presentation. The bottom-sheet action toggles demo GPS off and on. Turning demo GPS off changes the navigation mode and causes the simulated vehicle marker to move through the fusion engine’s inertial integration path; restoring demo GPS returns the state to GNSS-assisted navigation. Turning demo mode off uses the real device GNSS path instead of the simulator.

## Verified model contract

| Property | Verified value |
| --- | --- |
| Checkpoint | `models/cnn_feature_c_lowspeed/cnn_feature_c_lowspeed.pt` |
| Architecture | Conv1d 6→32, Conv1d 32→64, temporal mean pool, Dense 64→64, velocity head, stationary head |
| Original input | `(batch, 20, 6)` float32, then permuted internally to channel-first |
| TFLite input | `[1, 6, 20]` float32 |
| Window | 20 samples |
| Training cadence | 10 Hz, 2.0-second windows, stride 10 |
| Feature order | Linear Accel X/Y/Z, Gyroscope Yaw/Pitch/Roll selected from canonical indices `[0,1,2,6,7,8]` |
| Normalization | `(value - train_mean) / train_std` per selected channel |
| Outputs | `velocity_ms` and `stationary_logit`, each shape `[1]` |
| Conversion check | Max absolute PyTorch vs float32 TFLite difference: `2.86e-06` on verification input |

The conversion path was PyTorch checkpoint → fixed-shape ONNX → TensorFlow SavedModel → float32 TFLite. The verified artifact is included at `assets/models/velocity_cnn.tflite`.

## Run and validate

Install Flutter 3.47 or newer and Android Studio/SDK, then run:

```bash
flutter pub get
flutter analyze
flutter test --dart-define=FLUTTER_TEST=true
flutter build apk --debug
```

The generated APK is written to:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

For a real-device run, enable location permission and motion access when prompted. Android permissions are in `android/app/src/main/AndroidManifest.xml`; iOS usage descriptions are in `ios/Runner/Info.plist`.

## Main files changed

| File | Purpose |
| --- | --- |
| `lib/main.dart` | App entry point and theme |
| `lib/screens/navigation_screen.dart` | Vibrant map-first navigation UI |
| `lib/models/navigation_models.dart` | Snapshot, sensor, and position models |
| `lib/services/ai_model_service.dart` | Real TFLite model loading, normalization, and inference |
| `lib/services/sensor_service.dart` | Live accelerometer/gyroscope 10 Hz windows |
| `lib/services/fusion_engine.dart` | GNSS seeding, weak-GNSS correction, and inertial integration |
| `lib/services/navigation_services.dart` | Live/demo state machine and mode handoff |
| `assets/models/velocity_cnn.tflite` | Recovered trained model converted to TFLite |
| `assets/models/norm_params.json` | Training normalization metadata |
| `android/app/src/main/AndroidManifest.xml` | Android GNSS/motion permissions |
| `ios/Runner/Info.plist` | iOS GNSS/motion usage descriptions |
| `test/widget_test.dart` | App rendering test |

## Important limitations

The recovered project’s trained model is a velocity estimator. It does not itself provide a complete learned map matcher, pitch/roll/yaw alignment network, or AI fusion model. This app therefore implements the available verified model plus deterministic GNSS/IMU fusion and trajectory integration. A production lane-level system should add the team’s ESKF/RBPF/map-matching engine and validate drift against IO-VNBD and the SIH benchmark protocol on physical devices.
