//
// File:     Waypoint/Cloud/SharedCloud.swift
// Owner:    B (Guidance) with D (Cloud)
// Purpose:  ONE `SupabaseClient` for the whole app (built from Info.plist SupabaseURL / SupabaseAnonKey), shared by the map-sync code
//           (`CloudController`) and the guidance narrator (`ProxyNarrator` -> the `narrate` Edge Function).
// Why:      Two clients would each hold their own copy of the signed-in session and both refresh the same refresh token, and Supabase rotates
//           those. One client = one session.
// nil:      cloud not configured (no URL / key in Config/Local.xcconfig): everything cloud-related, including narration, stays off.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE for narration (the map sync path is unchanged).
//
import Foundation
import WaypointCore

enum SharedCloud {

    static let client: SupabaseClient? = {
        guard let config = SupabaseConfig.validated(
            urlString: Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            anonKey: Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String) else { return nil }
        return SupabaseClient(config: config, sessionStore: KeychainSessionStore())
    }()
}
