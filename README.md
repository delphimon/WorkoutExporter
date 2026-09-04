# Activity Manager and Activity Archive

Activity Manager is a local-first iPhone app for browsing Apple Health workouts, inspecting route and sensor detail, calculating transparent derived metrics, and exporting durable Activity Packages. The same repository also contains the shared core for the planned Activity Archive Mac companion app. Existing Xcode target and bundle identifiers retain the `WorkoutExporter` name so upgrades preserve installed app data.

> Screenshot capture slots and the real-device QA checklist are in [`Screenshots/README.md`](Screenshots/README.md).

## Requirements

- Xcode 27.0 beta (build 27A5228h), installed as `/Applications/Xcode-beta.app`
- iOS 17.0 deployment target
- Swift 6 language mode with complete strict-concurrency checking
- A real iPhone for HealthKit validation; Simulator uses deterministic sample workouts

The implementation is compiled against the iOS 27.0 SDK with Xcode beta. It uses async `HKHealthStore.requestAuthorization`, `HKSampleQueryDescriptor`, and `HKWorkoutRouteQueryDescriptor` APIs. Apple documents that read denial is intentionally indistinguishable from an empty or limited result set:

- [Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [Running queries with Swift concurrency](https://developer.apple.com/documentation/healthkit/running-queries-with-swift-concurrency)
- [HKWorkoutRouteQueryDescriptor](https://developer.apple.com/documentation/healthkit/hkworkoutroutequerydescriptor)

## Build

1. Open `WorkoutExporter.xcodeproj`.
2. Select the `WorkoutExporter` target and choose a Development Team.
3. Confirm the HealthKit capability is present and the bundle identifier is unique for your team.
4. Build for iPhone.

Command-line build:

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project WorkoutExporter.xcodeproj \
  -scheme WorkoutExporter \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
```

## HealthKit setup

The target contains the HealthKit entitlement and `NSHealthShareUsageDescription`. The app passes an empty share set and never writes Health data. Requested types are centralized in `HealthKitMappings.swift`, with a reason for each type.

On first launch, choose **Review Health Access**. In a Debug build, **Explore with Sample Workouts** loads all deterministic scenarios without requiring HealthKit.

HealthKit cannot prove per-type read approval. “No accessible workouts” may mean no workouts exist, access was denied, or access was restricted to a window with no matching samples.

## Features

- Read-only Health authorization
- Reverse-chronological workout browser with search, filters, refresh, and multi-selection
- Lazy Apple Maps route thumbnails with a protected, bounded 30-day device cache and conservative nearby place-name suggestions
- Editable location tags that override only the secondary Maps suggestion, never the activity type
- SF Symbol activity icons beside workout type names
- Immediate native detail summary while route and sample queries load concurrently
- Responsive synchronized route position and touch-scrubbable heart-rate, pace, and elevation charts; bounded display-only series retain original extrema while exports keep every source sample
- Heart-rate zone detail with explicit formulas, inputs, BPM boundaries, and an optional age-based maximum-HR estimate from Health date of birth
- Full date filters and grouped filtered totals for distance, duration, and native elevation gain
- HealthKit workout values preserved unchanged, with supplemental derived values kept separate
- A nonredundant detailed Activity Package containing exact source evidence, biometric samples, provenance, and a supplemental GPX 1.1 route when available
- Summary CSV plus customizable JSON, detailed CSV tables, GPX, and TCX interoperability exports
- SHA-256 manifest, schema documentation, package README, safe filenames
- Standard share sheet / Files handoff
- Persistent exported-status badges, an unexported-only filter, and reusable temporary packages
- Metric and US customary display units, including round slider increments in the selected scheme
- Debug-only synthetic fixtures, including long workouts and partial failure cases

## Privacy

There are no accounts, analytics, ads, developer-operated remote APIs,
automatic uploads, or background transmission. Apple Maps processes route
coordinates when providing map imagery and nearby place-name suggestions.
Temporary exports older than 24 hours are removed at launch. See
[PRIVACY.md](PRIVACY.md).

## Tests

```sh
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild test \
  -project WorkoutExporter.xcodeproj \
  -scheme WorkoutExporter \
  -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' \
  -parallel-testing-enabled NO
```

Distance, pace, speed, and elevation presentation always follow the selected metric or US customary scheme. Canonical exported raw values retain their original units and unit labels.

See [TESTING.md](TESTING.md) for real-device checks and simulator limitations.

## Project map

- `App/`: dependency composition and application entry point
- `Domain/`: HealthKit-independent models, units, typed errors, metrics
- `HealthKit/`: live adapters, centralized requested types, synthetic client
- `Export/`: Activity Package adapter, interoperability writers, package builder, manifest hashing, ZIP
- `Features/`: authorization, list, detail, export, and settings UI
- `Persistence/`: user settings, export history, cached-package references, and location tags
- `WorkoutExporterTests/`: deterministic unit and integration coverage
- `Packages/ActivityArchiveCore/`: shared, platform-neutral `.activitypkg` models, identity, validation, secure ZIP reader/writer, and migration contract for iPhone and Mac targets

Related documentation: [architecture](ARCHITECTURE.md), [export format](EXPORT_FORMAT.md), [testing](TESTING.md), [known limitations](KNOWN_LIMITATIONS.md).
