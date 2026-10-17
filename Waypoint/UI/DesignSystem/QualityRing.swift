//
// File:     Waypoint/UI/DesignSystem/QualityRing.swift
// Owner:    U3 (UI flows)
// Purpose:  Circular progress for ARKit mapping quality with the word beside it.
//           VoiceOver: "Mapping quality, Extending, 60 percent".
// Status:   DONE.
//
import SwiftUI
import WaypointCore

struct QualityRing: View {
    let quality: ScanQuality
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: quality.progress)
                    .stroke(Theme.color(for: quality), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: quality)
                if quality == .mapped {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 0) {
                Text("Mapping").font(.caption).foregroundStyle(.secondary)
                Text(quality.word).font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mapping quality")
        .accessibilityValue("\(quality.word), \(Int(quality.progress * 100)) percent")
    }
}

struct QualityRing_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading) {
            ForEach(ScanQuality.allCases, id: \.self) { QualityRing(quality: $0) }
        }
        .padding()
    }
}
