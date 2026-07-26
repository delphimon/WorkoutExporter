# Privacy

Workout Exporter is local-first:

- Health data is read and processed locally on the iPhone.
- Route coordinates are provided to Apple's MapKit services when the app renders
  a route thumbnail or requests a nearby trail, physical feature, or neighborhood
  name. Results are labeled as Apple Maps suggestions and cached only in memory.
- Exports are created only after an explicit user action.
- The user chooses the destination through Apple's share sheet.
- No workout data is transmitted to the developer.
- No analytics, advertising SDK, remote account, developer-operated server
  processing, automatic cloud upload, or background transmission exists.
- Release code does not log raw Health data.
- Complete exports are not persisted by the app as a library.
- Temporary exports older than 24 hours are removed at launch.
- Source and device metadata can be excluded from exports.

The privacy manifest declares no tracking or developer-collected data. It
declares the `UserDefaults` required-reason API with reason `CA92.1`. This must
be reviewed again whenever frameworks or storage behavior change.

HealthKit read authorization is deliberately private. A successful authorization request does not prove that any read type was granted, and the app does not claim otherwise.
