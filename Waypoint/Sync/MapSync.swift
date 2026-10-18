//
// File:     Waypoint/Sync/MapSync.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  Peer-to-peer map sharing with MultipeerConnectivity. No server, no accounts, and it
//           works on campus Wi-Fi that blocks device-to-device traffic (it can use Bluetooth /
//           peer-to-peer Wi-Fi). All phones advertise AND browse the service "waypoint-map" and
//           discover each other; to avoid both sides inviting each other, only the peer whose display
//           name sorts lower sends the invitation.
// SECURITY (decision D-012): a malicious map could steer a blind user somewhere unsafe, so
//           * incoming connection requests need the user's approval (`pendingInvitation`),
//           * incoming maps are decoded + `MapBundle.validate()`d, then held in `pendingMap` until the
//             user approves; only then does `MapStore.importBundle` write anything to disk,
//           * sessions use encryptionPreference .required; MultipeerConnectivity gives no strong peer
//             identity, so the human check ("is this my teammate's phone?") is the real control.
// Transfer: A map is packed into a `MapBundle` (JSON; includes the binary ARWorldMaps as base64),
//           written to a temp file `<name>.waypointmap` and sent with `sendResource`. After the
//           receiver approves, `MapStore.importBundle` MERGES it with any existing copy of the
//           same map id (this is how "anyone can extend a building's map" works).
// Needs:    Info.plist keys (already in project.yml): NSLocalNetworkUsageDescription and
//           NSBonjourServices = _waypoint-map._tcp/_udp. The first launch shows a Local Network
//           permission prompt - tap Allow, or sync silently never connects.
// Fallback: If Multipeer misbehaves, SyncView also offers a share-sheet export (AirDrop/Files).
// Status:   SCAFFOLD, compiles; needs a 2-phone test. TODO(D): version-header handshake so phones
//           auto-send only when the other is older; progress UI via the Progress returned by
//           sendResource.
//
import Combine
import MultipeerConnectivity
import WaypointCore

final class MapSync: NSObject, ObservableObject {

    static let serviceType = "waypoint-map" // 1-15 chars: lowercase letters, digits, hyphens

    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var status = "Not searching"
    @Published private(set) var lastReceivedMapName: String?

    /// Name of a nearby phone asking to connect. The UI must call `respondToInvitation`.
    @Published private(set) var pendingInvitation: String?
    /// A validated map received from a peer, waiting for the user to accept or reject it.
    /// NOTHING is written to disk until `respondToIncomingMap(accept: true)` (security finding, D-012).
    @Published private(set) var pendingMap: IncomingMap?

    struct IncomingMap: Identifiable {
        let id = UUID()
        let peerName: String
        let bundle: MapBundle
        var summary: String {
            "\"\(bundle.map.name)\" from \(peerName): \(bundle.map.nodes.count) places, \(bundle.map.edges.count) connections"
        }
    }

    private var invitationHandler: ((Bool, MCSession?) -> Void)?
    private static let maxIncomingFileBytes = 120_000_000

    /// Called on the main queue after a map was imported (so the UI can reload the list).
    var onMapImported: ((BuildingMap) -> Void)?

    private let store: MapStore
    private let myPeerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    init(store: MapStore, deviceName: String) {
        self.store = store
        self.myPeerID = MCPeerID(displayName: deviceName)
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: Self.serviceType)
        self.browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        status = "Searching for nearby phones..."
        Log.sync.info("sync started as \(self.myPeerID.displayName)")
    }

    func stop() {
        if pendingInvitation != nil { respondToInvitation(accept: false) }
        pendingMap = nil
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        connectedPeers = []
        status = "Not searching"
    }

    /// Answer to `pendingInvitation`. Declining (or `stop()`) refuses the connection.
    func respondToInvitation(accept: Bool) {
        invitationHandler?(accept, accept ? session : nil)
        invitationHandler = nil
        pendingInvitation = nil
    }

    /// Answer to `pendingMap`. Only on accept is the bundle imported (validate + merge rules in
    /// `MapStore.importBundle`); a rejection from the store is shown in `status`.
    func respondToIncomingMap(accept: Bool) {
        guard let incoming = pendingMap else { return }
        pendingMap = nil
        guard accept else { status = "Rejected \(incoming.bundle.map.name)"; return }
        do {
            let imported = try store.importBundle(incoming.bundle)
            lastReceivedMapName = imported.name
            status = "Imported \(imported.name) from \(incoming.peerName)"
            onMapImported?(imported)
        } catch MapStoreError.rejected(let reason) {
            status = "Refused map: \(reason)"
            Log.sync.error("import refused: \(reason)")
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Sends one map (with its world maps) to a connected peer.
    func send(mapId: UUID, to peer: MCPeerID) {
        // The receiving phone refuses a scan file over the limit, so do not even build the bundle (SharePolicy).
        let verdict = store.shareVerdict(mapId: mapId)
        if verdict.isLocalOnly { status = SharePolicy.message(verdict) ?? "Too large to share."; return }
        do {
            let fileURL = try store.writeBundleFile(id: mapId)
            session.sendResource(at: fileURL, withName: fileURL.lastPathComponent, toPeer: peer) { [weak self] error in
                DispatchQueue.main.async {
                    if let error {
                        self?.status = "Send failed: \(error.localizedDescription)"
                        Log.sync.error("send failed: \(error.localizedDescription)")
                    } else {
                        self?.status = "Sent to \(peer.displayName)"
                    }
                }
            }
            status = "Sending to \(peer.displayName)..."
        } catch {
            status = "Could not prepare map: \(error.localizedDescription)"
        }
    }
}

// MARK: - MCSessionDelegate

extension MapSync: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeers = session.connectedPeers
            self.status = session.connectedPeers.isEmpty
                ? "Searching for nearby phones..."
                : "Connected: " + session.connectedPeers.map(\.displayName).joined(separator: ", ")
        }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        guard let localURL, error == nil else {
            Log.sync.error("receive failed: \(error?.localizedDescription ?? "no file")")
            return
        }
        // Decode + validate here, but do NOT import: the user must approve first.
        do {
            let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? 0
            guard size <= Self.maxIncomingFileBytes else { throw MapStoreError.rejected("File is too large.") }
            let bundle = try JSONDecoder().decode(MapBundle.self, from: Data(contentsOf: localURL))
            try bundle.validate()
            DispatchQueue.main.async {
                self.pendingMap = IncomingMap(peerName: peerID.displayName, bundle: bundle)
                self.status = "\(peerID.displayName) wants to share a map"
            }
        } catch {
            Log.sync.error("rejected incoming map: \(error.localizedDescription)")
            DispatchQueue.main.async { self.status = "Ignored an invalid map from \(peerID.displayName)" }
        }
    }

    // Unused but required by the protocol.
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
}

// MARK: - Discovery

extension MapSync: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Never auto-accept: ask the user. Only one prompt at a time; extra requests are declined.
        DispatchQueue.main.async {
            guard self.pendingInvitation == nil else { invitationHandler(false, nil); return }
            self.invitationHandler = invitationHandler
            self.pendingInvitation = peerID.displayName
        }
    }
}

extension MapSync: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Only the lower-sorting name invites, so the pair does not cross-invite.
        if myPeerID.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
