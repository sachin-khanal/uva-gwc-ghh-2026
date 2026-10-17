//
// File:     Waypoint/UI/DesignSystem/Banner.swift
// Owner:    U3 (UI flows)
// Purpose:  Inline warning/info banner (icon + text + optional action). When it appears it is announced to
//           VoiceOver users (scanner banners are not spoken aloud: the volunteer can see them).
// Status:   DONE.
//
import SwiftUI

struct Banner: View {
    enum Kind { case info, warning, error }

    let text: String
    var kind: Kind = .warning
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.headline)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(Theme.Space.m)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .onAppear { Announcer.voiceOverOnly(text) }
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct Banner_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Banner(text: "Moving too fast. Slow down.")
            Banner(text: "This iPhone has no LiDAR, so you'll get a demo scan.", kind: .info)
            Banner(text: "Save failed.", kind: .error, actionTitle: "Retry") {}
        }
        .padding()
    }
}
