//
// File:     Waypoint/UI/DesignSystem/Theme.swift
// Owner:    U3 (UI flows)
// Purpose:  Design tokens for the new interface (docs/UI_PLAN.md §5.1): spacing, corner radii, colours and
//           target sizes, plus display names/symbols for node kinds. Built only on system styles, so Dark Mode,
//           Dynamic Type, Bold Text, Increase Contrast and Reduce Transparency keep working.
//           Navigator colours are a fixed dark, high-contrast palette (>= 7:1 text contrast, WCAG AAA).
// Status:   DONE.
//
import SwiftUI
import UIKit
import WaypointCore

enum Theme {

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let chip: CGFloat = 12
        static let card: CGFloat = 20
        static let hero: CGFloat = 28
    }

    /// Scanner accent (sighted volunteer screens).
    static let accent = Color.teal
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let screenBackground = Color(uiColor: .systemGroupedBackground)

    /// Navigator palette: always dark, always high contrast.
    enum Nav {
        static let background = Color.black
        static let surface = Color(white: 0.13)
        static let surfaceStroke = Color(white: 0.32)
        static let primary = Color(red: 1.0, green: 0.84, blue: 0.04)   // yellow, black text on it
        static let onPrimary = Color.black
        static let text = Color.white
        static let secondaryText = Color(white: 0.82)                   // ~13:1 on black
        static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
        static let caution = Color(red: 1.0, green: 0.62, blue: 0.04)
        /// Minimum height of any navigator control.
        static let minTarget: CGFloat = 88
    }

    /// Scanner HUD colour for a mapping quality (always paired with a word, never colour alone).
    static func color(for quality: ScanQuality) -> Color {
        switch quality {
        case .notAvailable: return .red
        case .limited: return .orange
        case .extending: return .yellow
        case .mapped: return .green
        }
    }
}

extension NodeKind {
    var displayName: String {
        switch self {
        case .corridor: return "Path point"
        case .door: return "Door"
        case .stairs: return "Stairs"
        case .elevator: return "Elevator"
        case .room: return "Room"
        case .junction: return "Junction"
        }
    }

    var symbolName: String {
        switch self {
        case .corridor: return "circle.fill"
        case .door: return "door.left.hand.open"
        case .stairs: return "figure.stairs"
        case .elevator: return "arrow.up.arrow.down.square"
        case .room: return "mappin.and.ellipse"
        case .junction: return "arrow.triangle.branch"
        }
    }

    /// Kinds the volunteer can tag, in palette order.
    static let taggable: [NodeKind] = [.room, .door, .stairs, .elevator, .junction]
}

/// Dims slightly while pressed; no scaling, so it is safe with Reduce Motion.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
