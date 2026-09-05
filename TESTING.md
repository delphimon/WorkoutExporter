# Testing

## Automated tests

The unit target covers route distance and point series, invalid points, GPS jumps, moving/stopped thresholds, pause handling, native-versus-derived elevation, heart-rate statistics and zones, distance/time splits, units, list filters/sorts/pagination, exported-status persistence, location tags, cached-package validation, filenames, CSV escaping/line endings, JSON compatibility, GPX/TCX structure, indexed heart-rate matching, CRC-32, streaming SHA-256, ZIP signatures, progress/cancellation/partial completion, off-main export execution, and manifest integrity. Activity Package integration tests validate stable identity, exact elevation and biometric source values and units, authoritative versus supplemental route roles, missing-route states, sensitive-data exclusions, nonredundant presets, and multiple-workout wrapping.

The shared `ActivityArchiveCore` package separately tests round trips, stable content identity, streaming file payloads, schema rejection, tamper detection, file limits, traversal/absolute paths, Unicode and case-folding collisions, undeclared files, and source-versus-normalized value separation.

The Activity Archive Mac scheme adds unit coverage for first-run state, valid and stale bookmarks,
interrupted-import recovery, selection cancellation, security-scope release, mixed import outcomes,
inaccessible files, and active cancellation. Its UI target covers local-only/FileVault/verified
backup guidance, missing-bookmark recovery, and the ready-vault Open and drag/drop entry points.

The UI target covers onboarding/privacy copy, synthetic-data entry, workout list/filter navigation, detail loading, export configuration, batch selection, exported-status filtering and clearing, cached-package sharing, and manual location tags without activity-type renaming.

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
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' \
  -parallel-testing-enabled NO
```

Use the Xcode beta binary explicitly on macOS 27 beta systems. The current checked toolchain is
Xcode 27.0 beta build 27A5252f with the iOS/macOS 27.0 SDKs. Disabling parallel testing avoids
unnecessary cloned simulators and duplicate destination names.

Run the complete Mac unit and UI suite on the host Mac:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  test -project WorkoutExporter.xcodeproj \
  -scheme ActivityArchive \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO
```

Verify the production configuration separately:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  build -project WorkoutExporter.xcodeproj \
  -scheme ActivityArchive \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64'
```

For Release acceptance, verify the signature, hardened runtime, sandbox/bookmark entitlements,
embedded privacy manifest, bundle identifier, and display name. UI automation on macOS can
occasionally time out before reaching the app; rerun a focused test with fresh derived data and do
not report that infrastructure error as an application assertion failure.

## Simulator

A Debug build exposes **Explore with Sample Workouts**. Simulator tests validate UI, normalization, calculations, and export behavior but do not validate HealthKit authorization or live queries.

## Real iPhone

Use an iPhone paired with an Apple Watch containing workouts:

1. Configure a Development Team and install the app.
2. Request Health access and test full, limited-window, and denied selections.
3. Compare workouts with zero, one, and multiple route objects.
4. Verify long outdoor workout map and chart responsiveness.
5. Export Basic, Detailed, and representative Custom formats. Validate the Activity Package with the shared reader and open its supplemental GPX in at least two independent tools.
6. Verify route gaps, pause events, interval heart-rate samples, source/device metadata, and timestamps.
7. Save through Files, share through AirDrop, cancel a large batch, and verify no background upload occurs.

Do not treat numerical differences from Apple Fitness as failures until the raw samples, pause model, smoothing settings, and documented proprietary Apple behavior are considered.

## Performance

The long fixture contains 10,000 points and 4,320 heart-rate samples. Raw export retains all values; display-only chart series are capped at 1,200 points. CSV/XML files, manifest hashes, and ZIP payloads are streamed in bounded chunks. GPX and TCX cache native sample series once and use logarithmic nearest-timestamp lookup rather than rescanning the complete sample set for every route point.
