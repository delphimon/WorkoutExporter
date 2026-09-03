# ActivityArchiveCore

`ActivityArchiveCore` is the cross-platform contract shared by Activity Manager on iPhone and
Activity Archive on Mac. Its first responsibility is the versioned `.activitypkg` interchange
format.

## Integrity and provenance rules

- Source-reported values and units are recorded exactly as supplied. Display conversion and any
  canonical calculations happen outside the immutable source evidence.
- Every payload has a SHA-256 digest, byte length, semantic role, media type, and authority level.
- `contentHash` covers the source identity, activity evidence metadata, annotations, omissions,
  privacy classifications, and sorted payload checksums. It intentionally excludes only package
  identity/revision and mutable generation metadata.
- The reader rejects path traversal, absolute paths, ambiguous paths, case-insensitive collisions,
  unlisted files, encrypted archives, symbolic links, compression, multi-disk archives, checksum
  mismatches, and configured size/count violations.
- Package publication is atomic. A failed or cancelled write does not replace an existing package.

## Compatibility

The schema name is `com.delphimon.activity-archive.package` and the current schema version is
`1.0.0`. New package readers must reject unknown major schema versions until an explicit migration
is available. The current iPhone ZIP/JSON exports remain supported as source artifacts; the
Activity Manager adapter will wrap their authoritative files and HealthKit source identity in an
Activity Package without rewriting the original bytes.

`ActivityPackageIdentity.stablePackageID(for:)` derives the persistent package ID from the stable
source activity ID. Later revisions reuse that ID and increment `packageRevision`.

## Validation

Use the Xcode Beta toolchain used by the applications:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test --package-path Packages/ActivityArchiveCore
```
