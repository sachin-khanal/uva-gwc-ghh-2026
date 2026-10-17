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
    var dark = false

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let points = PlanLayout.project(map.nodes, width: Float(geo.size.width), height: Float(geo.size.height), padding: 32)
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
        let onRoute = Set(route)

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
