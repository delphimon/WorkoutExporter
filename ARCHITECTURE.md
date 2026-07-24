# Architecture

## Boundaries

```text
SwiftUI views → observable view models → service protocols
                                      ↙                ↘
                         Live HealthKit adapter    Synthetic adapter
                                      ↓
                           HealthKit-free domain model
                              ↙                 ↘
                       Metric engine        Export writers
```

The UI does not execute HealthKit queries. `HealthKitClient`, `WorkoutRepository`, `WorkoutRouteRepository`, `WorkoutMetricCalculating`, `WorkoutExporting`, and `ExportPackageBuilding` define test seams. HealthKit objects are normalized before entering the metric or export layers.

## Concurrency

- HealthKit access is isolated in `LiveHealthKitClient`, an actor.
- Query descriptors use Swift concurrency.
- UI models are `@MainActor`.
- Export APIs are async, cancellation-aware, and yield while processing batches.
- Multiple-workout package generation is intentionally bounded to one workout at a time in v1 to avoid simultaneous large in-memory route series.

## Data principles

- Original sample timestamps, intervals, values, units, source/device identity, safe metadata, route identifiers, and route sequence are retained.
- HealthKit workout distance, elevation gain, energy, heart rate, speed, and other available statistics are never smoothed or overwritten.
- Native speeds, `CLLocation` speeds, route-derived speeds, and smoothed values have distinct provenance.
- Low-quality points remain in raw export and carry quality flags; calculations may exclude them using documented settings.
- Route membership is preserved so gaps and separate route objects are never silently joined.

## Metrics

The deterministic supplemental engine applies configurable maximum accuracy, maximum route-gap duration, maximum plausible speed, and moving-speed threshold. Explicit pause/resume events drive event-aware moving time. A separate threshold-based result is retained. Existing HealthKit workout statistics always take precedence, and elevation gain is read directly from `HKMetadataKeyElevationAscended` when present.

These algorithms are Workout Exporter algorithms, not reconstructions of Apple Fitness.

## Persistence and security

Only user preferences persist. Complete exports are staged in the temporary directory, use complete file protection when written as ZIP, and are removed after 24 hours unless the user explicitly saves or shares them.

## Future macOS companion

The versioned JSON envelope and package manifest depend only on Codable domain structures. A macOS importer can decode packages without HealthKit. FIT support can be added behind `WorkoutExporting` after a maintained, correctly licensed implementation is identified and tested.
