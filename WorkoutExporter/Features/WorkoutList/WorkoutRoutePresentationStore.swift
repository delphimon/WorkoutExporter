import MapKit
import Observation
import SwiftUI
import UIKit

struct WorkoutRoutePresentation {
    var thumbnail: UIImage?
    var placeLabel: WorkoutPlaceLabel?
}

enum WorkoutRoutePresentationState {
    case loading
    case loaded(WorkoutRoutePresentation)
    case unavailable
}

@MainActor
@Observable
final class WorkoutRoutePresentationStore {
    private(set) var states: [UUID: WorkoutRoutePresentationState] = [:]
    private var pending: [Request] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private let renderer: any WorkoutRouteThumbnailRendering
    private let placeResolver: any WorkoutPlaceResolving
    private let maximumConcurrentLoads: Int
    private let maximumCachedPresentations: Int
    private var completedOrder: [UUID] = []

    init(
        renderer: any WorkoutRouteThumbnailRendering = AppleMapThumbnailRenderer(),
        placeResolver: any WorkoutPlaceResolving = AppleMapsWorkoutPlaceResolver(),
        maximumConcurrentLoads: Int = 2,
        maximumCachedPresentations: Int = 120
    ) {
        self.renderer = renderer
        self.placeResolver = placeResolver
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
        self.maximumCachedPresentations = max(1, maximumCachedPresentations)
    }

    func state(for workoutID: UUID) -> WorkoutRoutePresentationState? {
        states[workoutID]
    }

    func enqueue(workout: WorkoutSummary, client: any HealthKitClient) {
        guard workout.hasRoute, states[workout.id] == nil else { return }
        states[workout.id] = .loading
        pending.append(Request(workout: workout, client: client))
        startPendingLoads()
    }

    func reset() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        pending.removeAll()
        states.removeAll()
        completedOrder.removeAll()
    }

    private func startPendingLoads() {
        while activeTasks.count < maximumConcurrentLoads, !pending.isEmpty {
            let request = pending.removeFirst()
            let task = Task { [weak self] in
                guard let self else { return }
                let presentation = await self.makePresentation(for: request)
                guard !Task.isCancelled else { return }
                self.finish(workoutID: request.workout.id, presentation: presentation)
            }
            activeTasks[request.workout.id] = task
        }
    }

    private func makePresentation(for request: Request) async -> WorkoutRoutePresentation? {
        do {
            guard let preview = try await request.client.fetchWorkoutRoutePreview(
                id: request.workout.id
            ) else {
                return nil
            }
            let thumbnail = try? await renderer.render(preview: preview)
            let placeLabel = try? await placeResolver.resolve(
                workout: request.workout,
                preview: preview
            )
            return WorkoutRoutePresentation(
                thumbnail: thumbnail,
                placeLabel: placeLabel
            )
        } catch {
            return nil
        }
    }

    private func finish(
        workoutID: UUID,
        presentation: WorkoutRoutePresentation?
    ) {
        activeTasks.removeValue(forKey: workoutID)
        if let presentation {
            states[workoutID] = .loaded(presentation)
        } else {
            states[workoutID] = .unavailable
        }
        completedOrder.removeAll { $0 == workoutID }
        completedOrder.append(workoutID)
        while completedOrder.count > maximumCachedPresentations {
            states.removeValue(forKey: completedOrder.removeFirst())
        }
        startPendingLoads()
    }

    private struct Request {
        var workout: WorkoutSummary
        var client: any HealthKitClient
    }
}

@MainActor
protocol WorkoutRouteThumbnailRendering {
    func render(preview: WorkoutRoutePreview) async throws -> UIImage
}

@MainActor
struct AppleMapThumbnailRenderer: WorkoutRouteThumbnailRendering {
    private let size = CGSize(width: 76, height: 64)

    func render(preview: WorkoutRoutePreview) async throws -> UIImage {
        let coordinates = preview.coordinates.map(\.clCoordinate)
        guard !coordinates.isEmpty else {
            throw WorkoutExporterError.noAccessibleData
        }
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = UITraitCollection.current.displayScale
        options.mapRect = Self.mapRect(for: coordinates)
        options.mapType = .mutedStandard
        options.showsBuildings = false
        let snapshot = try await MKMapSnapshotter(options: options).start()
        let format = UIGraphicsImageRendererFormat()
        format.scale = options.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            snapshot.image.draw(at: .zero)
            context.cgContext.setLineCap(.round)
            context.cgContext.setLineJoin(.round)
            context.cgContext.setStrokeColor(UIColor.systemBlue.cgColor)
            context.cgContext.setLineWidth(3)
            for segment in preview.segments {
                guard let first = segment.first else { continue }
                let path = UIBezierPath()
                path.move(to: snapshot.point(for: first.clCoordinate))
                for coordinate in segment.dropFirst() {
                    path.addLine(to: snapshot.point(for: coordinate.clCoordinate))
                }
                path.stroke()
            }
            if let first = preview.segments.first?.first {
                drawMarker(
                    at: snapshot.point(for: first.clCoordinate),
                    color: .systemGreen,
                    context: context.cgContext
                )
            }
            if let last = preview.segments.last?.last {
                drawMarker(
                    at: snapshot.point(for: last.clCoordinate),
                    color: .systemRed,
                    context: context.cgContext
                )
            }
        }
    }

    private func drawMarker(
        at point: CGPoint,
        color: UIColor,
        context: CGContext
    ) {
        let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
        context.setFillColor(color.cgColor)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(1.5)
        context.fillEllipse(in: rect)
        context.strokeEllipse(in: rect)
    }

    private static func mapRect(
        for coordinates: [CLLocationCoordinate2D]
    ) -> MKMapRect {
        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            let pointRect = MKMapRect(x: point.x, y: point.y, width: 0.1, height: 0.1)
            rect = rect.isNull ? pointRect : rect.union(pointRect)
        }
        let centerLatitude = coordinates.map(\.latitude).reduce(0, +)
            / Double(coordinates.count)
        let mapPointsPerMeter = 1 / MKMetersPerMapPointAtLatitude(centerLatitude)
        let minimumPadding = 250 * mapPointsPerMeter
        let horizontalPadding = max(rect.size.width * 0.12, minimumPadding)
        let verticalPadding = max(rect.size.height * 0.12, minimumPadding)
        return rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
    }
}

@MainActor
protocol WorkoutPlaceResolving {
    func resolve(
        workout: WorkoutSummary,
        preview: WorkoutRoutePreview
    ) async throws -> WorkoutPlaceLabel?
}

@MainActor
struct AppleMapsWorkoutPlaceResolver: WorkoutPlaceResolving {
    func resolve(
        workout: WorkoutSummary,
        preview: WorkoutRoutePreview
    ) async throws -> WorkoutPlaceLabel? {
        guard let kind = WorkoutActivityPresentation.placeKind(
            for: workout.activityName
        ) else {
            return nil
        }
        let request = MKLocalSearch.Request()
        request.region = coordinateRegion(for: preview.coordinates)
        switch kind {
        case .hike:
            request.naturalLanguageQuery = "Hiking Trail"
            request.resultTypes = .pointOfInterest
            if #available(iOS 18.0, *) {
                request.resultTypes = [.pointOfInterest, .physicalFeature]
                request.regionPriority = .required
            }
        case .neighborhood:
            request.naturalLanguageQuery = "Neighborhood"
            request.resultTypes = .address
            if #available(iOS 18.0, *) {
                request.addressFilter = MKAddressFilter(including: [.subLocality])
                request.regionPriority = .required
            }
        }

        let response = try await MKLocalSearch(request: request).start()
        let candidates = response.mapItems.compactMap { item -> WorkoutPlaceCandidate? in
            guard let name = item.name else { return nil }
            let coordinate: CLLocationCoordinate2D
            if #available(iOS 26.0, *) {
                coordinate = item.location.coordinate
            } else {
                coordinate = item.placemark.coordinate
            }
            return WorkoutPlaceCandidate(
                name: name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
        return WorkoutPlaceNameSelector.select(
            kind: kind,
            candidates: candidates,
            route: preview.coordinates
        )
    }

    private func coordinateRegion(
        for coordinates: [WorkoutRouteCoordinate]
    ) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(.world)
        }
        var minimumLatitude = first.latitude
        var maximumLatitude = first.latitude
        var minimumLongitude = first.longitude
        var maximumLongitude = first.longitude
        for coordinate in coordinates.dropFirst() {
            minimumLatitude = min(minimumLatitude, coordinate.latitude)
            maximumLatitude = max(maximumLatitude, coordinate.latitude)
            minimumLongitude = min(minimumLongitude, coordinate.longitude)
            maximumLongitude = max(maximumLongitude, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minimumLatitude + maximumLatitude) / 2,
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max((maximumLatitude - minimumLatitude) * 1.25, 0.01),
                longitudeDelta: max((maximumLongitude - minimumLongitude) * 1.25, 0.01)
            )
        )
    }
}

private extension WorkoutRouteCoordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
