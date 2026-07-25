# Testing

## Automated tests

The test target covers route distance, invalid points, GPS jumps, moving time, pause handling, elevation, heart-rate statistics, splits, units, filenames, CSV escaping/line endings, JSON schema, GPX/TCX parsing, indexed heart-rate matching, CRC-32, streaming SHA-256, ZIP signatures, progress phases, off-main export execution, and manifest integrity.

All 15 deterministic fixtures are generated in `SyntheticWorkoutFactory`:

1. Clean outdoor run
2. Hike with elevation and stops
3. Walk with auto-pause events
4. No route
5. No heart rate
6. Multiple route objects
7. Poor GPS accuracy
8. Implausible GPS jump
9. Time-zone boundary
10. Crossing midnight
11. Multisport
12. Very long workout with 10,000 points
13. Interval-valued heart rate
14. Conflicting HealthKit and route distance
15. Partial query failures

Run:

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  test -project WorkoutExporter.xcodeproj \
  -scheme WorkoutExporter \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO
```

Use the Xcode beta binary explicitly on macOS beta systems. Disabling parallel testing also avoids unnecessary cloned simulators for this single unit-test bundle.

## Simulator

A Debug build exposes **Explore with Sample Workouts**. Simulator tests validate UI, normalization, calculations, and export behavior but do not validate HealthKit authorization or live queries.

## Real iPhone

Use an iPhone paired with an Apple Watch containing workouts:

1. Configure a Development Team and install the app.
2. Request Health access and test full, limited-window, and denied selections.
3. Compare workouts with zero, one, and multiple route objects.
4. Verify long outdoor workout map and chart responsiveness.
5. Export each format and open it in at least two independent tools.
6. Verify route gaps, pause events, interval heart-rate samples, source/device metadata, and timestamps.
7. Save through Files, share through AirDrop, cancel a large batch, and verify no background upload occurs.

Do not treat numerical differences from Apple Fitness as failures until the raw samples, pause model, smoothing settings, and documented proprietary Apple behavior are considered.

## Performance

The long fixture contains 10,000 points and 4,320 heart-rate samples. Raw export retains all values; maps render a polyline and charts use native chart drawing rather than one SwiftUI view per point. CSV/XML files, manifest hashes, and ZIP payloads are streamed in bounded chunks. GPX and TCX cache the native heart-rate samples once and use logarithmic nearest-timestamp lookup rather than rescanning the complete sample set for every route point.
