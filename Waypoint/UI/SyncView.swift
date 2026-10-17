//
// File:     Waypoint/UI/SyncView.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  Sheet for sharing maps: (1) nearby phones via Multipeer, (2) the Supabase cloud library (upload
//           shared canonical maps, refresh, download), (3) share-sheet export per map (AirDrop / Files) as the
//           offline fallback. Anything that arrives from another person needs a tap to import.
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
                CloudSection(cloud: app.cloud, maps: app.maps)
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

/// Supabase library controls. A separate view so it OBSERVES CloudController (SyncView only observes
/// AppState, which would not redraw when the cloud status or pending download changes).
/// All actions show a message in `cloud.status` when cloud is not configured or offline.
private struct CloudSection: View {
    @ObservedObject var cloud: CloudController
    let maps: [BuildingMap]

    var body: some View {
        Section("Cloud library (Supabase)") {
            Text(cloud.status).font(.footnote)
            if cloud.isConfigured {
                ForEach(maps) { map in
                    Button("Upload \"\(map.name)\" (shared building map)") { cloud.push(mapId: map.id, name: map.name, share: true) }
                }
                Button("Refresh library") { cloud.refresh() }
                ForEach(cloud.remote) { item in
                    Button("Download \"\(item.row.name)\" v\(item.row.version)\(item.isMine ? " (mine)" : "")") {
                        cloud.download(item)
                    }
                }
            }
        }
        .disabled(cloud.isBusy)
        // Security (D-012 / D-015): someone else's map is never imported without this explicit tap.
        .alert("Import this cloud map?",
               isPresented: Binding(get: { cloud.pendingDownload != nil }, set: { _ in })) {
            Button("Import") { cloud.respondToPendingDownload(accept: true) }
            Button("Reject", role: .cancel) { cloud.respondToPendingDownload(accept: false) }
        } message: {
            Text(cloud.pendingDownload?.summary ?? "")
        }
    }
}

/// Holds the MapSync so SwiftUI re-renders when its @Published values change.
final class SyncHolder: ObservableObject {
    @Published var sync: MapSync? {
        didSet { cancellable = sync?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
    private var cancellable: Any?
}
