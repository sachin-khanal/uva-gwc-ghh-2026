//
// File:     Waypoint/UI/DesignSystem/HeroButton.swift
// Owner:    U3 (UI flows)
// Purpose:  The big, full-width primary button used by both flows (docs/UI_PLAN.md §5.2). One VoiceOver
//           element: label = "title. subtitle", plus an optional hint. Navigator styles are at least 88 pt tall
//           (`navPrimary` 120 pt) so they are easy to find and hit without looking.
// Status:   DONE.
//
import SwiftUI

struct HeroButton: View {

    enum Style {
        case primary, secondary, destructive   // scanner (follows light/dark)
        case navPrimary, navSecondary          // navigator (fixed high-contrast)
    }

    let title: String
    var subtitle: String?
    var systemImage: String?
    var style: Style = .primary
    var hint: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.l) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title2.weight(.semibold))
                        .frame(width: 32)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(isNav ? Font.title2.weight(.bold) : Font.headline)
                        .fontDesign(.rounded)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .opacity(0.85)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            .overlay {
                if style == .navSecondary {
                    RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                        .strokeBorder(Theme.Nav.surfaceStroke, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(subtitle.map { "\(title). \($0)" } ?? title)
        .accessibilityHint(hint ?? "")
    }

    private var isNav: Bool { style == .navPrimary || style == .navSecondary }

    private var minHeight: CGFloat {
        switch style {
        case .navPrimary: return 120
        case .navSecondary: return Theme.Nav.minTarget
        default: return 60
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .primary
        case .destructive: return .red
        case .navPrimary: return Theme.Nav.onPrimary
        case .navSecondary: return Theme.Nav.text
        }
    }

    private var background: Color {
        switch style {
        case .primary: return Theme.accent
        case .secondary: return Theme.cardBackground
        case .destructive: return Color.red.opacity(0.14)
        case .navPrimary: return Theme.Nav.primary
        case .navSecondary: return Theme.Nav.surface
        }
    }
}

struct HeroButton_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            VStack(spacing: 12) {
                HeroButton(title: "New scan", subtitle: "Walk the building once", systemImage: "viewfinder") {}
                HeroButton(title: "Extend a map", systemImage: "plus.square.on.square", style: .secondary) {}
                HeroButton(title: "Delete", style: .destructive) {}
            }
            .padding()
            .previewDisplayName("Scanner")

            VStack(spacing: 12) {
                HeroButton(title: "Start guidance", subtitle: "Room 204", systemImage: "figure.walk", style: .navPrimary) {}
                HeroButton(title: "Change destination", style: .navSecondary) {}
            }
            .padding()
            .background(Theme.Nav.background)
            .environment(\.dynamicTypeSize, .accessibility3)
            .previewDisplayName("Navigator, large text")
        }
    }
}
