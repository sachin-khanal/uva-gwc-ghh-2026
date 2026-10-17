//
// File:     Waypoint/UI/SyncView.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  Sheet for sharing maps: shows nearby connected phones and a per-map "Send" button
//           (Multipeer), plus a share-sheet export per map (AirDrop / Files) as the fallback.
// Status:   SCAFFOLD. Syncing runs only while this sheet is open (start on appear, stop on disappear).
//
import SwiftUI
import MultipeerConnectivity
import WaypointCore

struct SyncView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var holder = SyncHolder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(holder.sync?.status ?? "Starting...")
                    if let name = holder.sync?.lastReceivedMapName {
                        Text("Last received: \(name)")
                    }
                }
                Section("Nearby phones") {
                    let peers = holder.sync?.connectedPeers ?? []
                    if peers.isEmpty { Text("None connected yet").foregroundStyle(.secondary) }
                    ForEach(peers, id: \.self) { peer in
                        Menu(peer.displayName) {
                            ForEach(app.maps) { map in
                                Button("Send \"\(map.name)\"") { holder.sync?.send(mapId: map.id, to: peer) }
                            }
                        }
                    }
                }
                Section("Export (AirDrop / Files)") {
                    ForEach(app.maps) { map in
                        if let url = try? app.store.writeBundleFile(id: map.id) {
                            ShareLink(item: url) { Label(map.name, systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            }
            .navigationTitle("Share maps")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            // Security (D-012): nothing connects or is imported without an explicit tap.
            .alert("Connect to \(holder.sync?.pendingInvitation ?? "")?",
                   isPresented: Binding(get: { holder.sync?.pendingInvitation != nil }, set: { _ in })) {
                Button("Connect") { holder.sync?.respondToInvitation(accept: true) }
                Button("Decline", role: .cancel) { holder.sync?.respondToInvitation(accept: false) }
            } message: {
                Text("Only accept phones belonging to your team.")
            }
            .alert("Import this map?",
                   isPresented: Binding(get: { holder.sync?.pendingMap != nil }, set: { _ in })) {
                Button("Import") { holder.sync?.respondToIncomingMap(accept: true) }
                Button("Reject", role: .cancel) { holder.sync?.respondToIncomingMap(accept: false) }
            } message: {
                Text(holder.sync?.pendingMap?.summary ?? "")
            }
        }
        .onAppear {
            let sync = MapSync(store: app.store, deviceName: app.deviceName)
            sync.onMapImported = { _ in app.reloadMaps() }
            holder.sync = sync
            sync.start()
        }
        .onDisappear { holder.sync?.stop() }
    }
}

/// Holds the MapSync so SwiftUI re-renders when its @Published values change.
final class SyncHolder: ObservableObject {
    @Published var sync: MapSync? {
        didSet { cancellable = sync?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
    private var cancellable: Any?
}
