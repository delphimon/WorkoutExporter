# Activity Archive implementation ledger

Last updated: 2026-09-04

This file is the repository handoff for the two-application Activity Archive expansion. GitHub
issues remain the requirements and status authority; this document records cross-issue sequencing,
architecture decisions, validation commands, and the exact resume point for another engineer or
agent.

## Product boundary

- **Activity Manager** is the existing iPhone app. Keep bundle identifier
  `com.delphimon.WorkoutExporter` and all compatible local state; only its display name changes.
- **Activity Archive** is a separate macOS app target in this repository.
- `Packages/ActivityArchiveCore` is the platform-neutral boundary shared by both apps.
- The Mac vault is the canonical archive. The iPhone remains the authoritative collector for data
  it can read from HealthKit.
- Raw payloads, route points, biometric samples, source-reported statistics, values, units, and
  foreign fields are immutable evidence. Never smooth, rewrite, round, or unit-convert them in
  storage.
- Display conversions and future canonical calculations must be separately labeled, versioned
  derivatives with provenance. They must never overwrite source evidence.
- Activity type and title/location label are separate fields. A route or location name must never
  replace the activity type.

The detailed requirements are tracked by umbrella issue
[#34](https://github.com/delphimon/WorkoutExporter/issues/34) and its child issues.

## Delivered milestones

### Shared Activity Package contract — complete

- Issue: [#39](https://github.com/delphimon/WorkoutExporter/issues/39)
- Pull request: [#42](https://github.com/delphimon/WorkoutExporter/pull/42)
- Merge commit: `d5a3f60`
- Result: versioned `.activitypkg` models, stable identities, atomic ZIP writer, bounded defensive
  reader, checksums, provenance, exact source physical values, and 15 package security/integrity
  tests.

### Activity Manager package export — implementation complete, acceptance dependencies open

- Issue: [#37](https://github.com/delphimon/WorkoutExporter/issues/37)
- Pull request: [#43](https://github.com/delphimon/WorkoutExporter/pull/43)
- Merge commit: `470a65ac7d30b6ffb83c0379b2e00116e5dbcb5f`
- Result: in-place display-name change, Detailed Activity Package export, exact HealthKit source
  statistics and units, bounded route/metric payload streaming, cancellation/progress, multi-workout
  outer ZIP, supplemental GPX, preserved custom legacy formats, and regression coverage.
- Still open by design: durable new/changed/revision collection belongs to #38; live HealthKit and
  physical-device validation belongs to #40.

## Work in progress

### #44 durable vault and idempotent import engine

Working branch: `agent/activity-archive-vault`

Implemented locally:

- `ActivityArchiveVault` Swift package product for macOS and iOS.
- Documented vault layout with private managed directories.
- Immutable SHA-256 object storage with streaming ingestion, atomic publication, collision
  verification, read-only objects, strict lowercase ASCII hash paths, and symbolic-link rejection.
- SQLite catalog schema v1 with WAL, full synchronization, secure deletion, foreign keys, explicit
  migration transaction, bounded busy handling, private database files, route R-tree, exact source
  statistics, import jobs, warnings, and immutable source observations.
- Distinct activity type, title/location label, and completeness fields to prevent semantic
  overloading in the future catalog.
- Activity Package, streaming GPX, and bounded GeoJSON import. Originals and foreign fields remain
  byte-for-byte in object storage; only searchable summaries are indexed.
- Idempotent reimport by package ID/revision/content hash. Conflicting immutable revisions are
  rejected without deleting either raw object.
- Low-disk preflight, interrupted-import cleanup, processed/rejected receipts, integrity audit, and
  cancellation-aware parsing off the vault actor.
- Defensive parser limits: no XML external-entity resolution, GeoJSON size/depth bounds, route-point
  bound, coordinate validation, and Boolean rejection in numeric coordinates.

Current automated evidence:

- 12 `ActivityArchiveVaultTests` pass on macOS with Xcode Beta.
- Existing 15 `ActivityArchiveCoreTests` pass unchanged.
- `ActivityArchiveVault` cross-compiles for `arm64-apple-ios17.0` against the Xcode Beta iPhoneOS 27
  SDK.
- Full Activity Manager build/unit/UI suite passes on the iPhone 17 Pro Max iOS 26.2 simulator with
  Xcode Beta.
- Strict Swift formatting, whitespace validation, and unsafe-force-operation scan pass for new code.

Before opening the #44 pull request:

1. Re-run the package suite and iOS cross-compile after the final schema edits.
2. Re-run strict formatting and `git diff --check`.
3. Review the staged diff to prove the user-owned Xcode scheme change is excluded.
4. Commit only `Packages/ActivityArchiveCore` and this ledger.
5. Push the branch, open a PR linked to #44, and add exact validation evidence to #44.
6. Do not merge that PR without explicit user approval.

## Remaining P0 sequence

1. [#45](https://github.com/delphimon/WorkoutExporter/issues/45): add the Activity Archive macOS
   app target, create/open vault onboarding, security-scoped bookmark recovery, FileVault/backup
   guidance, Open panel, drag/drop, accessible progress, and onboarding/recovery tests. Depends on
   #44.
2. [#46](https://github.com/delphimon/WorkoutExporter/issues/46): source activity and import-job
   catalog, search/filter, immutable route overlays, source statistics, warnings, rejected imports,
   integrity UI, accessibility, and large-library performance. Depends on #44 and #45.
3. [#36](https://github.com/delphimon/WorkoutExporter/issues/36): duplicate candidates and
   whole-source canonical selection. Preserve all observations; make source-reported,
   source-recalculated, and canonical layers explicit. Depends on the Mac catalog.
4. [#38](https://github.com/delphimon/WorkoutExporter/issues/38): anchored incremental HealthKit
   collection, crash-safe outbound queue, provisional/final/tombstone revisions, retries, and
   diagnostics.
5. [#35](https://github.com/delphimon/WorkoutExporter/issues/35): QR pairing, authenticated local
   transport, resumable at-least-once package delivery, acknowledgement after durable Mac receipt,
   and revocation.
6. [#40](https://github.com/delphimon/WorkoutExporter/issues/40): real samples, performance,
   adversarial security, portable backup/restore, accessibility/localization, Xcode Beta, and
   physical-device release validation. This is the final P0 acceptance gate.

P1 items such as segment-level splicing, FIT/TCX fidelity, browser-assisted acquisition, and
multi-day trip editing remain outside P0 unless the umbrella issue is deliberately expanded.

## Resume checklist

1. Work in `/Users/andrew/development/WorkoutExporter`.
2. Read this file, the latest comments on #34 and the active child issue, and the relevant merged PR.
3. Confirm `git status -sb` and the active branch before editing.
4. Preserve the existing unstaged user change in
   `WorkoutExporter.xcodeproj/xcshareddata/xcschemes/WorkoutExporter.xcscheme`. Do not stage, revert,
   format, or otherwise alter it unless the user separately requests that change.
5. Use `/Applications/Xcode-beta.app` through `DEVELOPER_DIR`; the Mac is running a macOS 27 beta.
6. Keep each milestone on a feature branch and in a linked pull request. Record requirements,
   decisions, validation, remaining work, and blockers in GitHub before stopping.
7. Never report simulator, fixture, or compile checks as physical-device or live-HealthKit proof.

## Validation commands

Shared package on macOS:

```sh
cd Packages/ActivityArchiveCore
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

Vault target against the iPhone SDK:

```sh
cd Packages/ActivityArchiveCore
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build \
  --target ActivityArchiveVault \
  --triple arm64-apple-ios17.0 \
  --sdk /Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk \
  --scratch-path /private/tmp/ActivityArchiveVault-iOS-SPM
```

Full iPhone regression suite:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild test -quiet \
  -project WorkoutExporter.xcodeproj \
  -scheme WorkoutExporter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' \
  -derivedDataPath /private/tmp/WorkoutExporterVaultRegression \
  -parallel-testing-enabled NO
```

The exact simulator runtime can change with Xcode Beta. If the named destination is unavailable,
list installed destinations and select an installed iPhone runtime; document the substitution.
