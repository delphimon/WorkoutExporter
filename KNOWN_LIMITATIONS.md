# Known Limitations

- **Authorization ambiguity:** HealthKit does not reveal whether read access was denied for a type. Empty results can also mean no matching data or limited-window access.
- **Real-device requirement:** Simulator validates mocks and export logic, not live HealthKit behavior.
- **Partial routes:** Workouts can contain no route, multiple route objects, gaps, delayed samples, or points outside workout bounds. Raw points remain exported; unreliable segments may be excluded from derived totals.
- **Heart rate:** Missing or interval-valued heart-rate samples are preserved without fabricated interpolation. Display charts may connect points visually.
- **Apple Fitness differences:** Apple uses proprietary calibration, sensor fusion, and pause behavior. Activity Manager preserves Apple Health workout statistics unchanged; supplemental route-derived distance and moving time can still differ.
- **Running cadence:** The installed iOS 27.0 SDK exposes no separate `runningCadence` quantity identifier. Step-count samples are requested and preserved as cadence-compatible source data; the app does not invent an identifier.
- **Heart-rate zones:** Zone time is personal workout analysis based on the selected manual, percentage-of-maximum, or heart-rate-reserve setting. It is not medical guidance.
- **Route filtering:** Low-accuracy points and implausible or gapped segments remain in raw exports but may be excluded from supplemental derived series. The exact thresholds are exported.
- **ZIP compression:** Packages use the valid ZIP “stored” method and can be larger than deflated archives.
- **FIT:** Not implemented. Correct FIT encoding, interoperability tests, dependency maintenance, and licensing must be established first.
