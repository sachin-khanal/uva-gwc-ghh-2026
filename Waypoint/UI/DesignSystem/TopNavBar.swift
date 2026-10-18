//
// File:     Waypoint/UI/DesignSystem/TopNavBar.swift
// Owner:    U3 (UI flows)
// Purpose:  The row at the TOP of a screen with its back and exit controls (branch final-ui-changes, 2026-10-18):
//           Back on the left ("Buildings", "Places", "Scans"), Exit/Done on the right. Moving them up from the
//           bottom keeps the bottom of the screen for the screen's main action (Start guidance, Save & share).
//           `dark` = navigator styling: larger text and targets (60 pt) on the high-contrast palette.
//           VoiceOver reads it first in the screen, but the screens move focus to their heading on appear.
// Status:   DONE.
//
import SwiftUI

struct TopNavAction {
    let title: String
    var systemImage: String?
    var hint: String?
    let action: () -> Void
}

struct TopNavBar: View {
    var back: TopNavAction?
    var trailing: TopNavAction?
    var dark = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let back {
                button(back, defaultImage: "chevron.left")
            }
            Spacer(minLength: Theme.Space.s)
            if let trailing {
                button(trailing, defaultImage: nil)
            }
        }
        .frame(minHeight: dark ? 60 : 44)
    }

    private func button(_ item: TopNavAction, defaultImage: String?) -> some View {
        Button(action: item.action) {
            HStack(spacing: 6) {
                if let image = item.systemImage ?? defaultImage {
                    Image(systemName: image).accessibilityHidden(true)
                }
                Text(item.title)
            }
            .font(dark ? Font.title3.weight(.semibold) : Font.body.weight(.semibold))
            .foregroundStyle(dark ? Theme.Nav.text : Theme.accent)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: dark ? 56 : 44)
            .background(dark ? Theme.Nav.surface : Theme.cardBackground, in: Capsule())
            .overlay {
                if dark { Capsule().strokeBorder(Theme.Nav.surfaceStroke, lineWidth: 1) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(item.title)
        .accessibilityHint(item.hint ?? "")
    }
}

struct TopNavBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 24) {
            TopNavBar(back: TopNavAction(title: "Scans") {}, trailing: TopNavAction(title: "Done") {})
            TopNavBar(back: TopNavAction(title: "Buildings") {},
                      trailing: TopNavAction(title: "Exit", systemImage: "xmark") {}, dark: true)
                .background(Color.black)
        }
        .padding()
    }
}
