# Navigate Phase 1

A completely fresh Flutter Android navigation app. It is independent of the previous project and contains **no AI, dead reckoning, IMU, TFLite, demo mode, simulator window, or mock playback UI**.

## Features

The app requests location access on launch, waits for a real GPS fix, shows the live user location on OpenStreetMap, and provides a Google Maps-style two-row picker. The source row displays the live current location, while the destination row uses OpenStreetMap Nominatim autocomplete suggestions as the user types. Selecting a suggestion requests a driving route from the OSRM demo API, draws it as a blue line, places a red destination pin, continuously updates the blue user marker from GPS, and presents text-based turn instructions with distance and ETA.

| Area | Implementation |
| --- | --- |
| Platform | Android-only Flutter project |
| Map | `flutter_map` with OpenStreetMap tiles |
| Location | `location` package with live updates configured at one-second intervals |
| Search | OpenStreetMap Nominatim autocomplete with place suggestions and coordinates |
| Routing | OSRM HTTP API with GeoJSON route geometry and turn steps |
| UI | Search bar, recenter control, route line, current-location marker, destination pin, and navigation panel |
| Demo mode | Not included in this phase |
| AI/sensor fusion | Not included in this phase |

## Run

Install Flutter and Android Studio with an Android SDK, then run:

```bash
flutter pub get
flutter analyze
flutter test --dart-define=FLUTTER_TEST=true
flutter run
```

Build the Android debug APK with:

```bash
flutter build apk --debug
```

The output is `build/app/outputs/flutter-apk/app-debug.apk`.

## Testing on Android

Create a Pixel 4 or newer Android emulator with API 30 or higher. Enable Location in the emulator settings, launch the app, and grant location access when prompted. The map should center on the emulator’s current coordinate. To test movement without physically moving, open Extended Controls, choose **Location**, enter a coordinate, and use the **Routes** or **Play Route** option. The live blue marker should update as the emulator sends GPS events.

For a physical device, enable Developer Options and USB Debugging, install the APK, grant location access, and test outdoors or near a window for a stable initial fix. Route searches require network access because OSRM is called over HTTPS.

## Project structure

```text
lib/
  main.dart
  models/navigation_models.dart
  screens/map_screen.dart
  services/location_service.dart
  services/route_service.dart
  services/geocoding_service.dart
  widgets/navigation_panel.dart
  widgets/location_picker.dart
```

## Phase boundary

This is the live-navigation foundation only. Demo presentation controls and future AI or sensor-fusion features will be added separately later, without being part of this build.
