//
// File:     Waypoint/UI/DesignSystem/HoldToConfirmButton.swift
// Owner:    U3 (UI flows)
// Purpose:  Press-and-hold button for actions that must not happen by accident (Stop navigation).
//           A blind user brushing the screen cannot trigger it: the finger has to stay down for `duration`
//           while a bar fills. VoiceOver users cannot easily hold, so for them it is a normal button that asks
//           for confirmation ("Stop navigation? / Cancel") - same safety, different gesture.
// Status:   DONE, UNVERIFIED ON DEVICE.
//
import SwiftUI

struct HoldToConfirmButton: View {
    let title: String
    /// Title of the VoiceOver confirmation action, e.g. "Stop navigation".
    let confirmTitle: String
    var systemImage = "stop.fill"
    var duration: Double = 1.0
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var confirming = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .fill(Theme.Nav.surface)
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.Nav.danger)
                    .frame(width: geo.size.width * progress)
            }
            HStack(spacing: Theme.Space.m) {
                Image(systemName: systemImage).accessibilityHidden(true)
                Text(title)
            }
            .font(.title3.weight(.bold))
            .fontDesign(.rounded)
            .foregroundStyle(Theme.Nav.text)
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Nav.minTarget)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .strokeBorder(Theme.Nav.danger, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 60) {
            progress = 0
            action()
        } onPressingChanged: { pressing in
            withAnimation(pressing ? .linear(duration: duration) : .easeOut(duration: 0.2)) {
                progress = pressing ? 1 : 0
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(confirmTitle)
        .accessibilityHint("Double tap, then confirm.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { confirming = true }
        .confirmationDialog("\(confirmTitle)?", isPresented: $confirming, titleVisibility: .visible) {
            Button(confirmTitle, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct HoldToConfirmButton_Previews: PreviewProvider {
    static var previews: some View {
        HoldToConfirmButton(title: "Hold to stop", confirmTitle: "Stop navigation") {}
            .padding()
            .background(Color.black)
    }
}
