//
// File:     Waypoint/UI/Scanner/ScanSetupView.swift
// Owner:    U3 (UI flows)
// Purpose:  S2 "New scan": name the building and floor (combined into BuildingMap.name, no contract change),
//           see whether this phone can do a real LiDAR scan, read three short tips, start.
//           Marker capture is a placeholder until ROADMAP U1.7.
// Status:   SCAFFOLD.
//
import SwiftUI

struct ScanSetupView: View {
    let onStart: (String) -> Void
    let onBack: () -> Void

    @State private var building = ""
    @State private var floor = ""
    @FocusState private var focusedField: Field?

    private enum Field { case building, floor }

    private var mapName: String {
        let b = building.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = floor.trimmingCharacters(in: .whitespacesAndNewlines)
        return f.isEmpty ? b : "\(b) · Floor \(f)"
    }

    private var willUseMock: Bool { ServiceMode.current != .live || !DeviceCapabilities.hasLiDAR }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                TopNavBar(back: TopNavAction(title: "Scans", hint: "Back to the list of scans.", action: onBack))

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("New scan")
                        .font(.largeTitle.weight(.bold))
                        .fontDesign(.rounded)
                        .accessibilityAddTraits(.isHeader)
                    Text("Name the place you are about to map.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: Theme.Space.m) {
                    field("Building", placeholder: "e.g. Rice Hall", text: $building, field: .building)
                    field("Floor (optional)", placeholder: "e.g. 1", text: $floor, field: .floor)
                }

                deviceCard

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Before you start").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    tip("tortoise", "Walk slowly, about half your normal pace.")
                    tip("arrow.left.and.right", "Sweep the camera across walls and floor as you go.")
                    tip("tag", "Tag doors and rooms as you pass them, with their number.")
                    tip("qrcode.viewfinder", "Start marker: coming soon (roadmap U1.7).")
                }
                .padding(Theme.Space.l)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                HeroButton(title: "Start scanning", subtitle: mapName.isEmpty ? "Enter a building name first" : mapName,
                           systemImage: "record.circle", isEnabled: !building.trimmingCharacters(in: .whitespaces).isEmpty) {
                    focusedField = nil
                    onStart(mapName)
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.screenBackground)
        .scrollDismissesKeyboard(.interactively)
    }

    private var deviceCard: some View {
        Group {
            if !DeviceCapabilities.hasLiDAR {
                Banner(text: "This iPhone has no LiDAR, so you'll get a demo scan to try the screens.", kind: .info)
            } else if willUseMock {
                Banner(text: "Demo data is on (Settings). The scan will be simulated, not recorded.", kind: .info)
            } else {
                Banner(text: "LiDAR ready. This will record a real map.", kind: .info)
            }
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: text)
                .font(.title3)
                .textInputAutocapitalization(.words)
                .submitLabel(field == .building ? .next : .done)
                .focused($focusedField, equals: field)
                .onSubmit { focusedField = field == .building ? .floor : nil }
                .padding(Theme.Space.m)
                .frame(minHeight: 52)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .accessibilityLabel(title)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
        }
    }
}
