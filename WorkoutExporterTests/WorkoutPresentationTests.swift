import UIKit
import XCTest
@testable import WorkoutExporter

@MainActor
final class WorkoutPresentationTests: XCTestCase {
    func testActivitySymbolsMatchCommonWorkoutTypes() {
        XCTAssertEqual(
            WorkoutActivityPresentation.symbolName(for: "Hiking"),
            "figure.hiking"
        )
        XCTAssertEqual(
            WorkoutActivityPresentation.symbolName(for: "Outdoor Running"),
            "figure.run"
        )
        XCTAssertEqual(
            WorkoutActivityPresentation.symbolName(for: "Walking"),
            "figure.walk"
        )
        XCTAssertEqual(
            WorkoutActivityPresentation.symbolName(for: "Cycling"),
            "bicycle"
        )
        XCTAssertEqual(
            WorkoutActivityPresentation.symbolName(for: "Strength Training"),
            "dumbbell.fill"
        )
    }

    func testHikeNameRequiresCredibleNearbyAppleMapsCandidate() {
        let route = [
            WorkoutRouteCoordinate(latitude: 47.4880, longitude: -121.7230),
            WorkoutRouteCoordinate(latitude: 47.5000, longitude: -121.7300)
        ]
        let label = WorkoutPlaceNameSelector.select(
            kind: .hike,
            candidates: [
                WorkoutPlaceCandidate(
                    name: "Hiking Trail",
                    latitude: 47.4900,
                    longitude: -121.7240
                ),
                WorkoutPlaceCandidate(
                    name: "Mount Si Trail",
                    latitude: 47.4890,
                    longitude: -121.7240
                ),
                WorkoutPlaceCandidate(
                    name: "Unrelated Distant Trail",
                    latitude: 47.7000,
                    longitude: -121.9000
                )
            ],
            route: route
        )

        XCTAssertEqual(
            label,
            WorkoutPlaceLabel(
                name: "Mount Si Trail",
                kind: .hike,
                source: "Apple Maps"
            )
        )
    }

    func testNeighborhoodNameRejectsStreetAndDistantResults() {
        let route = [
            WorkoutRouteCoordinate(latitude: 37.7599, longitude: -122.4148),
            WorkoutRouteCoordinate(latitude: 37.7650, longitude: -122.4200)
        ]
        let label = WorkoutPlaceNameSelector.select(
            kind: .neighborhood,
            candidates: [
                WorkoutPlaceCandidate(
                    name: "Valencia Street",
                    latitude: 37.7600,
                    longitude: -122.4150
                ),
                WorkoutPlaceCandidate(
                    name: "Mission District",
                    latitude: 37.7600,
                    longitude: -122.4150
                ),
                WorkoutPlaceCandidate(
                    name: "Sunset District",
                    latitude: 37.7500,
                    longitude: -122.4900
                )
            ],
            route: route
        )

        XCTAssertEqual(label?.name, "Mission District")
        XCTAssertEqual(label?.kind, .neighborhood)
        XCTAssertNil(
            WorkoutPlaceNameSelector.select(
                kind: .neighborhood,
                candidates: [
                    WorkoutPlaceCandidate(
                        name: "Valencia Street",
                        latitude: 37.7600,
                        longitude: -122.4150
                    )
                ],
                route: route
            )
        )
    }

    func testRoutePresentationStoreLoadsOnceAndCachesResult() async {
        let detail = SyntheticWorkoutFactory.make(.hikeWithStops)
        let preview = WorkoutRoutePreview(
            workoutID: detail.id,
            segments: detail.routes.values.map {
                $0.map {
                    WorkoutRouteCoordinate(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            }
        )
        let client = PreviewClient(summary: detail.summary, preview: preview)
        let store = WorkoutRoutePresentationStore(
            renderer: StubRenderer(),
            placeResolver: StubPlaceResolver(),
            thumbnailCache: nil,
            maximumConcurrentLoads: 1
        )

        store.enqueue(workout: detail.summary, client: client)
        store.enqueue(workout: detail.summary, client: client)

        for _ in 0..<200 {
            if case .loaded = store.state(for: detail.id) { break }
            await Task.yield()
        }

        guard case .loaded(let presentation) = store.state(for: detail.id) else {
            return XCTFail("Expected the cached route presentation to load")
        }
        XCTAssertNotNil(presentation.thumbnail)
        XCTAssertEqual(presentation.placeLabel?.name, "Synthetic Trail")
        let firstRequestCount = await client.requestCount()
        XCTAssertEqual(firstRequestCount, 1)

        store.enqueue(workout: detail.summary, client: client)
        await Task.yield()
        let cachedRequestCount = await client.requestCount()
        XCTAssertEqual(cachedRequestCount, 1)
    }

    func testRouteThumbnailCachePersistsPresentationAcrossStores() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let detail = SyntheticWorkoutFactory.make(.hikeWithStops, index: 7)
        let preview = WorkoutRoutePreview(
            workoutID: detail.id,
            segments: detail.routes.values.map {
                $0.map {
                    WorkoutRouteCoordinate(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            }
        )
        let cache = WorkoutRouteThumbnailCache(directory: directory)
        let firstClient = PreviewClient(summary: detail.summary, preview: preview)
        let firstStore = WorkoutRoutePresentationStore(
            renderer: StubRenderer(),
            placeResolver: StubPlaceResolver(),
            thumbnailCache: cache,
            maximumConcurrentLoads: 1
        )
        firstStore.enqueue(workout: detail.summary, client: firstClient)
        for _ in 0..<100 {
            if case .loaded = firstStore.state(for: detail.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .loaded = firstStore.state(for: detail.id) else {
            return XCTFail("Expected the first presentation to finish caching")
        }
        let firstRequestCount = await firstClient.requestCount()
        XCTAssertEqual(firstRequestCount, 1)
        let cachedPresentation = await cache.presentation(for: detail.id)
        if cachedPresentation == nil {
            let cacheError = await cache.lastError
            XCTFail(
                "Expected persisted cache entry: "
                    + (cacheError ?? "unknown cache error")
            )
        }

        let secondClient = PreviewClient(summary: detail.summary, preview: preview)
        let secondStore = WorkoutRoutePresentationStore(
            renderer: StubRenderer(),
            placeResolver: StubPlaceResolver(),
            thumbnailCache: cache,
            maximumConcurrentLoads: 1
        )
        secondStore.enqueue(workout: detail.summary, client: secondClient)
        for _ in 0..<100 {
            if case .loaded = secondStore.state(for: detail.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .loaded(let presentation) = secondStore.state(for: detail.id) else {
            return XCTFail("Expected the persisted presentation to load")
        }
        XCTAssertEqual(presentation.placeLabel?.name, "Synthetic Trail")
        let secondRequestCount = await secondClient.requestCount()
        XCTAssertEqual(secondRequestCount, 0)
    }

    func testSyntheticRoutePreviewPreservesEveryCoordinateInSourceOrder() async throws {
        let detail = SyntheticWorkoutFactory.make(.hikeWithStops, index: 1)
        let expectedSegments = detail.routes
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map(\.value)
        let fetchedPreview = try await SyntheticHealthKitClient()
            .fetchWorkoutRoutePreview(id: detail.id)
        let preview = try XCTUnwrap(
            fetchedPreview
        )

        XCTAssertEqual(preview.segments.count, expectedSegments.count)
        for (previewSegment, expectedSegment) in zip(
            preview.segments,
            expectedSegments
        ) {
            XCTAssertEqual(previewSegment.count, expectedSegment.count)
            XCTAssertEqual(
                previewSegment.map(\.latitude),
                expectedSegment.map(\.latitude)
            )
            XCTAssertEqual(
                previewSegment.map(\.longitude),
                expectedSegment.map(\.longitude)
            )
        }
    }
}

private actor PreviewClient: HealthKitClient {
    nonisolated let isHealthDataAvailable = true
    let summary: WorkoutSummary
    let preview: WorkoutRoutePreview
    private(set) var previewRequestCount = 0

    init(summary: WorkoutSummary, preview: WorkoutRoutePreview) {
        self.summary = summary
        self.preview = preview
    }

    func requestReadAuthorization() async throws {}

    func fetchWorkouts(limit: Int) async throws -> [WorkoutSummary] {
        [summary]
    }

    func fetchWorkoutRoutePreview(id: UUID) async throws -> WorkoutRoutePreview? {
        previewRequestCount += 1
        return preview
    }

    func requestCount() -> Int {
        previewRequestCount
    }

    func fetchWorkoutDetail(
        id: UUID,
        settings: MetricCalculationSettings
    ) async throws -> WorkoutDetail {
        throw WorkoutExporterError.noAccessibleData
    }
}

@MainActor
private struct StubRenderer: WorkoutRouteThumbnailRendering {
    func render(preview: WorkoutRoutePreview) async throws -> UIImage {
        UIImage()
    }
}

@MainActor
private struct StubPlaceResolver: WorkoutPlaceResolving {
    func resolve(
        workout: WorkoutSummary,
        preview: WorkoutRoutePreview
    ) async throws -> WorkoutPlaceLabel? {
        WorkoutPlaceLabel(
            name: "Synthetic Trail",
            kind: .hike,
            source: "Apple Maps"
        )
    }
}
