//
// File:     Waypoint/UI/Scanner/StairsSheet.swift
// Owner:    U3 (UI flows) with A (maps)
// Purpose:  What the volunteer tells us when they tag a staircase or a lift: its NAME, which way it
//           goes, and where the handrail is.
//
// Why each field matters:
//   * NAME - the two ends of one staircase are recorded in SEPARATE maps (one per floor) and are
//     matched across them by name. Mistyping it on the second floor is the whole reason a building
//     never links up, so names already used here are offered as buttons rather than retyped.
//   * DIRECTION - "North Stairwell" on floor 1 and on floor 2 are the same staircase seen from
//     opposite ends. Without this we cannot tell which end we are standing at, so we cannot work out
//     where taking it lands you.
//   * HANDRAIL - a blind user reaching for a rail that is not there is why this is recorded at all.
//     ARKit's mesh classification has no railing class (wall, floor, ceiling, table, seat, window,
//     door, none), so the person holding the phone is the only source there will ever be.
//
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct StairsSheet: View {
    let kind: NodeKind
    /// Names already used in this map, so both ends of one staircase get the same one.
    let knownNames: [String]
    let onCancel: () -> Void
    let onSave: (String, StairsInfo) -> Void

    @State private var name = ""
    @State private var direction: StairsDirection = .up
    @State private var railings: RailingSide = .right
    @State private var steps = ""

    private var isLift: Bool { kind == .elevator }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isLift ? "Lift name, e.g. Main Lift" : "Stairwell name, e.g. North Stairwell",
                              text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("stairs.name")
                    if !knownNames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Space.s) {
                                ForEach(knownNames, id: \.self) { known in
                                    Button(known) { name = known }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .accessibilityIdentifier("stairs.knownNames")
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Use the SAME name on every floor. That is how the floors are joined up.")
                }

                Section {
                    Picker("Goes", selection: $direction) {
                        Text("Up").tag(StairsDirection.up)
                        Text("Down").tag(StairsDirection.down)
                        Text("Both ways").tag(StairsDirection.both)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("stairs.direction")
                } header: {
                    Text("Which way from here")
                } footer: {
                    Text("From where you are standing now. The other end of the same \(isLift ? "lift" : "staircase") goes the opposite way.")
                }

                if !isLift {
                    Section {
                        Picker("Handrail", selection: $railings) {
                            Text("Left").tag(RailingSide.left)
                            Text("Right").tag(RailingSide.right)
                            Text("Both").tag(RailingSide.both)
                            Text("None").tag(RailingSide.neither)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("stairs.railings")
                        TextField("Number of steps (optional)", text: $steps)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("stairs.steps")
                    } header: {
                        Text("Handrail")
                    } footer: {
                        Text("Facing the way the stairs go. This is spoken to the person walking, so they know which hand to reach with.")
                    }
                }
            }
            .navigationTitle(isLift ? "Tag a lift" : "Tag stairs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tag") {
                        onSave(trimmedName, StairsInfo(direction: direction,
                                                       railings: isLift ? nil : railings,
                                                       stepCount: Int(steps.trimmingCharacters(in: .whitespaces))))
                    }
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("stairs.save")
                }
            }
        }
    }
}

struct StairsSheet_Previews: PreviewProvider {
    static var previews: some View {
        StairsSheet(kind: .stairs, knownNames: ["North Stairwell", "South Stairwell"],
                    onCancel: {}, onSave: { _, _ in })
    }
}
