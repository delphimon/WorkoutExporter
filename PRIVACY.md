# Privacy

Activity Manager is local-first:

- Health data is read and processed locally on the iPhone.
- If Health grants access to date of birth, it is used in memory to calculate
  age on the workout date and estimate maximum heart rate. Date of birth and
  exact age are not persisted or exported. When heart-rate data is included,
  exports contain the resulting maximum-HR setting and zone boundaries so the
  calculation remains reproducible.
- Route coordinates are provided to Apple's MapKit services when the app renders
  a route thumbnail or requests a nearby trail, physical feature, or neighborhood
  name. Results are labeled as Apple Maps suggestions. Rendered thumbnails and
  suggestions may be cached on device for up to 30 days in a protected,
  backup-excluded cache capped at 200 entries.
- Exports are created only after an explicit user action.
- The user chooses the destination through Apple's share sheet.
- No workout data is transmitted to the developer.
- No analytics, advertising SDK, remote account, developer-operated server
  processing, automatic cloud upload, or background transmission exists.
- Release code does not log raw Health data.
- Complete exports are not persisted by the app as a library.
- Temporary exports older than 24 hours are removed at launch.
- Workout identifiers marked as exported, user-entered location tags, and
  temporary-package filenames are stored locally with complete file protection
  and excluded from backup. Missing or expired package references are pruned.
- A manual location tag changes only the local secondary label. It does not
  rename the HealthKit activity type or alter exported data.
- Source and device metadata can be excluded from exports.
- Detailed Activity Packages can contain health samples and precise route
  coordinates. They are created only on request, protected while on device,
  and shared only through a destination the user selects.

The privacy manifest declares no tracking or developer-collected data. It
declares the `UserDefaults` required-reason API with reason `CA92.1`. This must
be reviewed again whenever frameworks or storage behavior change.

HealthKit read authorization is deliberately private. A successful authorization request does not prove that any read type was granted, and the app does not claim otherwise.
