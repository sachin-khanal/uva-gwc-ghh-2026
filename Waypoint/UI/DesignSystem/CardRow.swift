//
// File:     Waypoint/UI/DesignSystem/CardRow.swift
// Owner:    U3 (UI flows)
// Purpose:  Tappable list row (maps, destinations, places): icon, title, detail, badges, chevron.
//           Combined into ONE VoiceOver element so a swipe moves row by row, not word by word.
//           `dark` = navigator styling (88 pt rows on the high-contrast palette).
// Status:   DONE.
//
import SwiftUI

struct CardRow: View {
    let title: String
    var detail: String?
    var systemImage: String
    var badges: [String] = []
    var dark = false
    var showsChevron = true
    var hint: String?
    /// Replaces the spoken label (e.g. a sentence instead of "About 11 m · 1 turn").
    var accessibilityText: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(dark ? Theme.Nav.primary : Theme.accent)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(dark ? Font.title3.weight(.semibold) : Font.headline)
                        .foregroundStyle(dark ? Theme.Nav.text : Color.primary)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(dark ? Theme.Nav.secondaryText : Color.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    if !badges.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(badges, id: \.self) { Badge(text: $0) }
                        }
                    }
                }
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(dark ? Theme.Nav.secondaryText : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, minHeight: dark ? Theme.Nav.minTarget : 64, alignment: .leading)
            .background(dark ? Theme.Nav.surface : Theme.cardBackground,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .modifier(OptionalAccessibilityLabel(text: accessibilityText))
        .accessibilityHint(hint ?? "")
    }
}

/// Applies an accessibility label only when one is given, keeping the combined label otherwise.
struct OptionalAccessibilityLabel: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.accessibilityLabel(text)
        } else {
            content
        }
    }
}

struct CardRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            CardRow(title: "Rice Hall · Floor 1", detail: "24 points · 3 places", systemImage: "building.2",
                    badges: ["Demo"]) {}
            CardRow(title: "Room 204", detail: "About 11 m · 1 turn · no stairs", systemImage: "mappin.and.ellipse",
                    dark: true) {}
        }
        .padding()
        .background(Color.black)
    }
}
