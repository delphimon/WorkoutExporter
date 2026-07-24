# Known Limitations

- **Authorization ambiguity:** HealthKit does not reveal whether read access was denied for a type. Empty results can also mean no matching data or limited-window access.
- **Real-device requirement:** Simulator validates mocks and export logic, not live HealthKit behavior.
- **Partial routes:** Workouts can contain no route, multiple route objects, gaps, delayed samples, or points outside workout bounds. Raw points remain exported; unreliable segments may be excluded from derived totals.
- **Heart rate:** Missing or interval-valued heart-rate samples are preserved without fabricated interpolation. Display charts may connect points visually.
- **Apple Fitness differences:** Apple uses proprietary calibration, sensor fusion, and pause behavior. Workout Exporter preserves Apple Health workout statistics unchanged; supplemental route-derived distance and moving time can still differ.
- **Running cadence:** The installed iOS 26.5 SDK exposes no separate `runningCadence` quantity identifier. Step-count samples are requested and preserved; the app does not invent an identifier.
- **Temperature and heart-rate-zone UI:** The domain can be extended, but detailed temperature export and configurable zone-boundary editing are not complete in this baseline.
- **CSV derived series:** Route CSV reserves supplemental speed and grade columns; unavailable columns remain blank rather than fabricating or smoothing values.
- **ZIP compression:** Packages use the valid ZIP “stored” method and can be larger than deflated archives.
- **Memory:** CSV and XML output is built in memory. A future writer should stream exceptionally large batches to disk.
- **FIT:** Not implemented. Correct FIT encoding, interoperability tests, dependency maintenance, and licensing must be established first.
