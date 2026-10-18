//
// File:     Waypoint/UI/DesignSystem/TagPalette.swift
// Owner:    U3 (UI flows)
// Purpose:  Grid of large tag buttons (Room, Door, Stairs, Point - NodeKind.taggable) for the live scan screen.
//           Adaptive columns so it reflows at large Dynamic Type sizes instead of truncating.
// Status:   DONE.
//
import SwiftUI
import WaypointCore

struct TagPalette: View {
    var isEnabled = true
    let onTag: (NodeKind) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
            ForEach(NodeKind.taggable, id: \.self) { kind in
                Button {
                    onTag(kind)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: kind.symbolName)
                            .font(.title3)
                            .accessibilityHidden(true)
                        Text(kind.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .foregroundStyle(Theme.accent)
                    .background(Theme.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.45)
                .accessibilityLabel("Tag \(kind.displayName)")
                .accessibilityHint("Adds a \(kind.displayName.lowercased()) about one metre in front of you, with the label above.")
            }
        }
    }
}

struct TagPalette_Previews: PreviewProvider {
    static var previews: some View {
        TagPalette { _ in }.padding()
    }
}
