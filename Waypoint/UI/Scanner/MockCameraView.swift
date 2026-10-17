//
// File:     Waypoint/UI/Scanner/MockCameraView.swift
// Owner:    U3 (UI flows)
// Purpose:  Stand-in for the live camera + LiDAR mesh when the scanner runs on demo data (or on an iPhone
//           without LiDAR): a dark perspective grid that slowly moves toward the viewer, like walking down a
//           corridor. Static when Reduce Motion is on. Decorative only, hidden from VoiceOver.
// Status:   DONE.
//
import SwiftUI

struct MockCameraView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .linearGradient(Gradient(colors: [Color(white: 0.2), Color(white: 0.04)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

                let horizon = size.height * 0.38
                let line = Color.teal
                let phase = reduceMotion ? 0 : CGFloat((t * 0.6).truncatingRemainder(dividingBy: 1))

                // Floor lines sliding toward the viewer.
                for i in 0..<14 {
                    let k = (CGFloat(i) + phase) / 14
                    let y = horizon + (size.height - horizon) * k * k
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(p, with: .color(line.opacity(0.15 + 0.5 * Double(k))), lineWidth: 1)
                }
                // Lines converging on the vanishing point.
                let vanish = CGPoint(x: size.width / 2, y: horizon)
                for i in -8...8 {
                    var p = Path()
                    p.move(to: vanish)
                    p.addLine(to: CGPoint(x: size.width / 2 + CGFloat(i) * size.width / 5, y: size.height))
                    context.stroke(p, with: .color(line.opacity(0.35)), lineWidth: 1)
                }
                // Ceiling, fainter.
                for i in -4...4 {
                    var p = Path()
                    p.move(to: vanish)
                    p.addLine(to: CGPoint(x: size.width / 2 + CGFloat(i) * size.width / 3, y: 0))
                    context.stroke(p, with: .color(line.opacity(0.15)), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct MockCameraView_Previews: PreviewProvider {
    static var previews: some View {
        MockCameraView().ignoresSafeArea()
    }
}
