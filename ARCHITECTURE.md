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
- Package generation is isolated in `ExportPackageBuilder`, an actor that keeps file generation, hashing, and archiving off the main actor.
- Export APIs report format-level progress and check cancellation while processing route points, samples, hashes, and archive chunks.
- Multiple-workout package generation is intentionally bounded to one workout at a time to avoid simultaneous large route series.
- Workout-list route presentations are loaded lazily, limited to two concurrent
  workouts, and cached in memory. A list refresh reuses the cache; switching
  between live and synthetic data clears it.
- CSV, GPX, TCX, SHA-256, and ZIP payloads are streamed in bounded chunks. Heart-rate samples are sorted once and matched to route points with binary search.

## Data principles

- Original sample timestamps, intervals, values, units, source/device identity, safe metadata, route identifiers, and route sequence are retained.
- HealthKit workout distance, elevation gain, energy, heart rate, speed, and other available statistics are never smoothed or overwritten.
- Native speeds, `CLLocation` speeds, and route-derived speeds have distinct provenance.
- Low-quality points remain in raw export and carry quality flags; calculations may exclude them using documented settings.
- Route membership is preserved so gaps and separate route objects are never silently joined.
- Route thumbnails draw the original coordinate sequence without changing or
  persisting route points.

## Metrics

The deterministic supplemental engine applies configurable maximum accuracy,
maximum route-gap duration, maximum plausible speed, moving/stopped run
thresholds, split mode, and heart-rate-zone method. Explicit pause/resume events
drive event-aware moving time. A separate threshold-based result is retained.
Recorded route coordinates, altitude, and speed remain unchanged.

Existing HealthKit workout values remain unchanged and are shown as the primary workout values. Elevation gain is read directly from `HKMetadataKeyElevationAscended` when present. Route-filtered elevation and route-derived distance are supplemental values with separate labels and provenance; they never replace or modify the workout activity’s values.

These algorithms are Workout Exporter algorithms, not reconstructions of Apple Fitness.

## Route presentation and place names

`WorkoutRoutePresentationStore` requests route coordinates only for rows that
need a preview. The live HealthKit actor caches each preview, and the presentation
store caches the rendered result. `MKMapSnapshotter` supplies map imagery.

For hiking, Apple Maps local search may suggest a nearby trail or physical
feature. For running and walking, it may suggest a neighborhood. Candidates
must have a non-generic name and be geographically close to the recorded route;
otherwise the app shows no name. The UI labels every accepted result as an
Apple Maps suggestion. These labels are presentation metadata only and never
replace or enter the HealthKit workout record or exported canonical data.

## Persistence and security

Only user preferences persist. Complete exports are staged in the temporary directory, written to a partial archive before atomic publication, use complete file protection when written as ZIP, and are removed after 24 hours unless the user explicitly saves or shares them.

## Future macOS companion

The versioned JSON envelope and package manifest depend only on Codable domain structures. A macOS importer can decode packages without HealthKit. FIT support can be added behind `WorkoutExporting` after a maintained, correctly licensed implementation is identified and tested.
