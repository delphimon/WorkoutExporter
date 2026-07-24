# Export Format 1.0.0

Canonical timestamps are ISO 8601 strings with fractional seconds and an explicit UTC offset. Every raw value retains its explicit HealthKit unit. Canonical normalized route units are meters (`m`), seconds (`s`), and meters per second (`m/s`). Presentation uses the selected metric or US customary scheme without altering stored/exported raw values.

## JSON

Top-level fields:

| Field | Meaning |
|---|---|
| `schemaName` | `com.delphimon.workout-export` |
| `schemaVersion` | Semantic schema version |
| `exporterVersion` | App marketing version |
| `exportedAt` | Export creation timestamp |
| `timeZoneIdentifier` | Exporting device time-zone identifier |
| `workout` | Normalized workout object |

`workout` fields:

| Field | Meaning |
|---|---|
| `summary` | ID, raw activity identifier/readable name, dates, duration, HealthKit distance/elevation gain/energy/heart-rate summaries, source/device, availability flags |
| `events` | Pause, resume, lap, segment, marker, or unknown events with intervals and metadata |
| `activities` | Multisport/structured activity segments |
| `statistics` | HealthKit statistic type, aggregation, value, and unit |
| `samples` | Quantity samples preserving start/end, value, unit, source, device, provenance, and metadata |
| `categorySamples` | Associated category sample identifiers, intervals, integer values, source, and metadata |
| `routes` | Dictionary keyed by source route UUID |
| `metadata` | Safe string representation of workout metadata |
| `derived` | Derived metric values, provenance, splits, and warnings |
| `metricSettings` | Exact thresholds and smoothing settings |
| `warnings` | Partial-data and quality notes |

Each route point includes UUID, route UUID, sequence, timestamp, latitude/longitude in decimal degrees, altitude and optional ellipsoidal altitude in meters, horizontal/vertical accuracy in meters, optional speed/speed accuracy in m/s, optional course/course accuracy in degrees, optional floor, and quality flags.

## CSV

All CSV is UTF-8 with RFC 4180 quoting and CRLF line endings.

### `samples.csv`

`workout_id`, `sample_type`, `start_time`, `end_time`, `value`, `unit`, `source_name`, `source_bundle_id`, `device_name`, `provenance`, `metadata_json`.

### `route.csv`

`workout_id`, `route_id`, `sequence`, `timestamp`, `latitude`, `longitude`, `altitude_m`, `horizontal_accuracy_m`, `vertical_accuracy_m`, `speed_mps`, `speed_accuracy_mps`, `course_deg`, `course_accuracy_deg`, `segment_distance_m`, `cumulative_distance_m`, `derived_speed_mps`, `smoothed_speed_mps`, `grade`, `quality_flags`.

Blank derived columns mean no reliable value was available; raw route data is never fabricated.

### `events.csv`

`workout_id`, `event_type`, `start_time`, `end_time`, `metadata_json`.

### `splits.csv`

`workout_id`, `index`, `start_time`, `end_time`, `distance_m`, `elapsed_s`, `moving_s`, `pace_s_per_km`, `speed_mps`, `elevation_gain_m`, `elevation_loss_m`, `average_hr_bpm`, `maximum_hr_bpm`.

### `statistics.csv`

`workout_id`, `sample_type`, `aggregation`, `value`, `unit`, `provenance`.

## GPX

GPX 1.1 uses one `trkseg` per HealthKit route object. Each track point includes coordinates, time, elevation, and Garmin TrackPoint heart-rate extension when a sample is within ten seconds. Unsupported fields are not placed in standard elements.

## TCX

Training Center Database v2 contains one activity and lap, route track points, position, altitude, heart rate, duration, distance, and calories when available. Running and cycling map to standard TCX sports; other activities map conservatively to `Other`.

## ZIP package

Stored-method ZIP archives are standards-compliant and intentionally uncompressed. Each workout directory contains the selected formats, `README.txt`, and `manifest.json`. The manifest lists relative path, MIME type, byte size, and lowercase SHA-256 for every generated payload file. Multi-workout archives also contain `index.csv`.
