//
// File:     Waypoint/UI/DesignSystem/MockBadge.swift
// Owner:    U3 (UI flows)
// Purpose:  Small capsule labels. `MockBadge` is shown on every screen fed by demo data so nobody mistakes
//           mock output for a real scan or real guidance (docs/UI_PLAN.md §5.2).
// Status:   DONE.
//
import SwiftUI

struct Badge: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: Capsule())
    }
}

struct MockBadge: View {
    var body: some View {
        Badge(text: "Demo data", systemImage: "theatermasks")
            .accessibilityLabel("Demo data, not a real scan")
    }
}

struct MockBadge_Previews: PreviewProvider {
    static var previews: some View {
        HStack { Badge(text: "Shared"); MockBadge() }.padding()
    }
}
