//
// File:     Waypoint/UI/DesignSystem/PlanView.swift
// Owner:    U3 (UI flows)
// Purpose:  Top-down floor plan of a BuildingMap drawn with Canvas (no 3D, no dependencies). Positions come
//           from PlanLayout (WaypointCore, tested). Corridor points are small dots, tagged places are labelled
//           circles, stairs edges are dashed orange, an optional route is drawn thicker in the accent colour,
//           and the start of the scan is marked. Pinch to zoom, double tap to reset.
// Accessibility: a picture is useless to VoiceOver, so the whole view is one element whose value lists the
//           places; the screens that use it also show the same places as a normal list.
// Status:   DONE (drawing), UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct PlanView: View {
    let map: BuildingMap
    /// Node ids of a route to highlight, start first.
    var route: [UUID] = []
    /// Where the user is now, MAP frame. Drawn as a heading arrow. nil = not localized / not navigating.
    var userPosition: SIMD3<Float>?
    /// Which way they face: radians, 0 = -z, positive toward +x.
    var userHeading: Float?
    var dark = false

    /// Stable id for the synthetic node used to project `userPosition` through the same transform
    /// as the map's nodes.
    private static let userPointId = UUID(uuidString: "00000000-0000-4000-8000-00000000FFFF")!

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            // The user's position is projected through the SAME transform by being laid out with the nodes.
            let laidOut = map.nodes + (userPosition.map {
                [MapNode(id: Self.userPointId, kind: .corridor, position: $0)]
            } ?? [])
            let points = PlanLayout.project(laidOut, width: Float(geo.size.width), height: Float(geo.size.height), padding: 32)
            Canvas { context, _ in
                draw(in: context, points: points)
            }
            .scaleEffect(min(4, max(1, scale * pinch)))
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .background(dark ? Theme.Nav.surface : Theme.cardBackground,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in scale = min(4, max(1, scale * value.magnification)) }
        )
        .onTapGesture(count: 2) { scale = 1 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Floor plan")
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(.isImage)
    }

    /// A triangle at the user's position pointing where they face. Map +x is right on screen and map
    /// -z is up, which is how PlanLayout projects, so heading 0 points up.
    private func drawUser(in context: GraphicsContext, points: [UUID: PlanPoint],
                          cg: (PlanPoint) -> CGPoint) {
        guard let p = points[Self.userPointId] else { return }
        let c = cg(p)
        let r: CGFloat = 9
        guard let heading = userHeading else {
            context.fill(Path(ellipseIn: CGRect(x: c.x - r / 2, y: c.y - r / 2, width: r, height: r)),
                         with: .color(.green))
            return
        }
        let angle = CGFloat(heading)
        func point(_ offsetAngle: CGFloat, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: c.x + sin(angle + offsetAngle) * radius,
                    y: c.y - cos(angle + offsetAngle) * radius)
        }
        var arrow = Path()
        arrow.move(to: point(0, r))
        arrow.addLine(to: point(2.5, r * 0.8))
        arrow.addLine(to: point(-2.5, r * 0.8))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(.green))
    }

    /// Points-per-metre of the current projection, measured from two nodes that are far apart.
    /// PlanLayout fits the map to the view, so the scale is only known after projecting.
    private func metresToPoints(_ points: [UUID: PlanPoint]) -> CGFloat {
        guard let a = map.nodes.first, let pa = points[a.id] else { return 1 }
        var best: CGFloat = 1
        for node in map.nodes.dropFirst() {
            guard let pb = points[node.id] else { continue }
            let metres = Geometry.horizontalDistance(a.position, node.position)
            guard metres > 1 else { continue }
            let onScreen = hypot(CGFloat(pb.x - pa.x), CGFloat(pb.y - pa.y))
            best = onScreen / CGFloat(metres)
            break
        }
        return best
    }

    private var accessibilitySummary: String {
        let names = map.destinations.compactMap(\.label)
        if names.isEmpty { return "\(map.nodes.count) path points, no labelled places" }
        return "\(names.count) places: " + names.joined(separator: ", ")
    }

    private var lineColor: Color { dark ? Color(white: 0.55) : Color.secondary }
    private var accent: Color { dark ? Theme.Nav.primary : Theme.accent }
    private var textColor: Color { dark ? Theme.Nav.text : Color.primary }

    private func draw(in context: GraphicsContext, points: [UUID: PlanPoint]) {
        func cg(_ p: PlanPoint) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }
        defer { drawUser(in: context, points: points, cg: cg) }
        let onRoute = Set(route)

        // Room floor areas (RoomExtent), so you can see what the scan actually understood as a room
        // rather than guessing from a pin. Drawn first, under everything else.
        for node in map.nodes {
            guard let extent = node.extent else { continue }
            let corners: [SIMD3<Float>] = [
                SIMD3(-extent.halfExtents.x, 0, -extent.halfExtents.y),
                SIMD3(extent.halfExtents.x, 0, -extent.halfExtents.y),
                SIMD3(extent.halfExtents.x, 0, extent.halfExtents.y),
                SIMD3(-extent.halfExtents.x, 0, extent.halfExtents.y),
            ].map { local in
                let c = cos(extent.yaw), sn = sin(extent.yaw)
                return SIMD3(extent.center.x + local.x * c + local.z * sn, 0,
                             extent.center.z - local.x * sn + local.z * c)
            }
            let projected = corners.compactMap { corner -> CGPoint? in
                points[node.id].map { anchor in
                    // Same scale as the layout: measure the corner relative to the node it belongs to.
                    let dx = corner.x - node.position.x
                    let dz = corner.z - node.position.z
                    return CGPoint(x: CGFloat(anchor.x) + CGFloat(dx) * metresToPoints(points),
                                   y: CGFloat(anchor.y) + CGFloat(dz) * metresToPoints(points))
                }
            }
            guard projected.count == 4 else { continue }
            var rect = Path()
            rect.move(to: projected[0])
            for corner in projected.dropFirst() { rect.addLine(to: corner) }
            rect.closeSubpath()
            context.fill(rect, with: .color(accent.opacity(0.12)))
            context.stroke(rect, with: .color(accent.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }

        // The route is drawn as its OWN polyline through the route nodes. It cannot be drawn by
        // highlighting map edges any more: RouteSimplifier collapses straight runs, so consecutive
        // route nodes often have no direct edge between them.
        if route.count > 1 {
            var line = Path()
            var started = false
            for id in route {
                guard let p = points[id] else { continue }
                if started { line.addLine(to: cg(p)) } else { line.move(to: cg(p)); started = true }
            }
            context.stroke(line, with: .color(accent),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }

        for edge in map.edges {
            guard let a = points[edge.from], let b = points[edge.to] else { continue }
            var path = Path()
            path.move(to: cg(a))
            path.addLine(to: cg(b))
            let isRoute = onRoute.contains(edge.from) && onRoute.contains(edge.to)
            let isStairs = edge.hazard == .stairs
            let color: Color = isStairs ? .orange : (isRoute ? accent : lineColor.opacity(0.6))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: isRoute ? 5 : 3, lineCap: .round, dash: isStairs ? [6, 5] : []))
        }

        let start = NavigateFlow.defaultStart(in: map, excluding: nil)
        for node in map.nodes {
            guard let p = points[node.id] else { continue }
            let c = cg(p)
            if node.kind == .corridor && node.id != start?.id {
                let r: CGFloat = 3
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(lineColor))
                continue
            }
            let r: CGFloat = 9
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let isStart = node.id == start?.id
            context.fill(dot, with: .color(isStart ? .green : (node.kind == .stairs ? .orange : accent)))
            context.stroke(dot, with: .color(dark ? .black : .white), lineWidth: 2)

            let text = isStart ? "Start" : (node.label ?? "")
            if !text.isEmpty {
                context.draw(Text(text).font(.caption.weight(.semibold)).foregroundStyle(textColor),
                             at: CGPoint(x: c.x + r + 5, y: c.y), anchor: .leading)
            }
        }
    }
}

struct PlanView_Previews: PreviewProvider {
    static var previews: some View {
        let a = MapNode(kind: .corridor, position: [0, 0, 0])
        let b = MapNode(kind: .corridor, position: [0, 0, -6])
        let room = MapNode(kind: .room, label: "Room 204", position: [1.5, 0, -6])
        let stairs = MapNode(kind: .stairs, label: "Stairs up", position: [0, 0, -9])
        let map = BuildingMap(name: "Preview", nodes: [a, b, room, stairs], edges: [
            MapEdge(from: a.id, to: b.id, distance: 6),
            MapEdge(from: b.id, to: room.id, distance: 1.5),
            MapEdge(from: b.id, to: stairs.id, distance: 3, hazard: .stairs),
        ])
        return PlanView(map: map, route: [a.id, b.id, room.id])
            .frame(height: 300)
            .padding()
    }
}
