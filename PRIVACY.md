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

Activity Archive on Mac is also local-first:

- The vault must be placed on local storage; the setup UI explicitly excludes cloud-synced and
  network locations.
- Original imports, source values, routes, job history, and warnings remain inside the selected
  vault. The app does not upload them.
- Persistent access is represented only by an app-scoped security bookmark protected in Keychain
  with when-unlocked, this-device-only accessibility. Health and route content is not copied into
  preferences, Keychain, or Application Support.
- The sandbox grants access only to user-selected read/write locations. The Release app uses the
  hardened runtime and does not include the debug `get-task-allow` entitlement.
- Setup recommends FileVault and a backup whose restoration has been tested. FileVault protects
  the volume; the vault layer does not claim to provide its own encryption at rest.
- The Mac privacy manifest declares no tracking or developer-collected data. It declares the disk
  space required-reason API with reason `85F4.1`, used only to confirm sufficient capacity before
  copying an import into immutable object storage.

Mac source catalog and map display:

- Catalog, import history, original filenames, source identities, warnings and error details are
  visible only inside the selected vault workflow. They are not logged or transmitted to a developer.
- Route previews are generated on explicit request and retained only in memory. Apple Maps may
  request basemap content for the displayed region; the UI explains this before loading an overlay.
  No source package, health statistics or biometric series is sent to a developer service.
- Disk-space reason `85F4.1` covers the visible capacity display; `E174.1` covers checking sufficient
  space before writing imported files. The earlier handoff described `85F4.1` alone as the preflight
  reason; that description is corrected here. Both reasons are now in the embedded Mac manifest.
  See [Apple's required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- Synthetic catalog launch fixtures remain inside `#if DEBUG`. Release has no synthetic-data launch
  modes, new persistence outside the vault, analytics, network-client entitlement or health uploads.
