//
// File:     Waypoint/Guidance/SpatialAudioGuide.swift
// Owner:    B (Navigation/Feedback)
// Purpose:  The "next turn is literally heard from that direction" beacon. A short looping ping
//           is played from a 3D position using AVAudioEnvironmentNode (HRTF binaural rendering).
//           The listener stays at the origin facing -z; instead of rotating the listener we
//           position the SOURCE relative to the phone (NavigationController converts the target
//           from world frame into the camera's local frame every tick).
// Coordinates (AVAudio3D): +x right, +y up, -z forward - same as an ARKit camera's local frame,
//           so a camera-local vector can be passed straight through.
// Needs:    Headphones for the full effect (AirPods/wired). On the phone speaker you only get a
//           weak left/right pan. Test both.
// Status:   SCAFFOLD. TODO(B): tune ping pitch/period vs distance (faster as you approach),
//           make arrival sound distinct, handle audio interruptions (calls) and route changes.
//
import AVFoundation
import simd

final class SpatialAudioGuide {

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private var isConfigured = false

    /// Beyond this distance the source is pulled in to this radius: far sources get quiet and
    /// directionally vague, but the direction is what matters to the user.
    private let maxSourceDistance: Float = 4

    func start() throws {
        if !isConfigured { try configure() }
        if !engine.isRunning { try engine.start() }
        if !player.isPlaying { player.play() }
        Log.guidance.info("spatial audio started")
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    /// - Parameter relativeToListener: target in the phone's local frame (meters), or nil to mute.
    func setTarget(relativeToListener v: SIMD3<Float>?) {
        guard let v else {
            player.volume = 0
            return
        }
        var p = v
        let len = simd_length(p)
        if len > maxSourceDistance { p = p / len * maxSourceDistance }
        player.volume = 1
        player.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
    }

    // MARK: Private

    private func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)

        engine.attach(environment)
        engine.attach(player)

        // Spatialization requires a MONO source into the environment node.
        let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(player, to: environment, format: mono)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.distanceAttenuationParameters.maximumDistance = 20
        environment.distanceAttenuationParameters.rolloffFactor = 0.4

        player.renderingAlgorithm = .HRTFHQ
        player.volume = 0 // muted until the first target is set

        player.scheduleBuffer(Self.makePingBuffer(format: mono), at: nil, options: .loops)
        isConfigured = true
    }

    /// 0.8 s loop: a 120 ms 880 Hz sine "ping" with a decaying envelope, then silence.
    /// Generated in code so we need no audio asset files in the repo.
    private static func makePingBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(sampleRate * 0.8)
        let pingFrames = Int(sampleRate * 0.12)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)!
        buffer.frameLength = totalFrames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(totalFrames) {
            if i < pingFrames {
                let t = Double(i) / sampleRate
                let envelope = Float(exp(-t * 25))
                samples[i] = Float(sin(2 * .pi * 880 * t)) * envelope * 0.8
            } else {
                samples[i] = 0
            }
        }
        return buffer
    }
}
