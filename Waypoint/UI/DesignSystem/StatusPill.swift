//
// File:     Waypoint/UI/DesignSystem/StatusPill.swift
// Owner:    U3 (UI flows)
// Purpose:  Glass capsule (icon + word) for HUD values over the camera: "Tracking OK", "12 points".
//           The icon is tinted, the word carries the meaning (never colour alone). One VoiceOver element.
// Status:   DONE.
//
import SwiftUI

struct StatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
        }
        .font(.footnote.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            StatusPill(text: "Tracking OK", systemImage: "checkmark.circle.fill", tint: .green)
            StatusPill(text: "12 points", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .padding()
        .background(Color.gray)
    }
}
