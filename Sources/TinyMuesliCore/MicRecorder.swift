@preconcurrency import AVFAudio
import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

/// Records the local microphone ("Me") with Apple's voice processing turned on.
///
/// Voice processing does echo cancellation: without it, if you're not wearing headphones,
/// the mic also picks up the other participants from your speakers, and they'd get
/// transcribed twice, once as "Me".
///
/// The input can change mid-meeting (AirPods connect, another input is chosen, the call app
/// reconfigures the mic). AVAudioEngine then stops itself and posts a configuration change; if
/// nobody restarts it, the mic track silently ends there. So capture is rebuilt on a new engine
/// whenever the engine's configuration or the default input changes, and a watchdog restarts it if
/// no audio arrives for `MicWatchdog.stallSeconds`. It keeps writing to the same track: the time
/// without audio becomes silence (`TrackWriter` places buffers by host time), so the track stays
/// aligned with system audio. A new sample rate continues in a new file (see `SegmentedTrack`).
@MainActor
public final class MicRecorder {
    private var engine = AVAudioEngine()
    /// The engine's input has been set up, so it needs tearing down (see `tearDownEngine`).
    private var engineUsed = false
    private var track: SegmentedTrack?
    /// Between start/resume and pause/stop: capture should be running.
    private var capturing = false
    private let heartbeat = Heartbeat()
    private var watchdog = MicWatchdog()
    private var watchdogTimer: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var pendingCheck: DispatchWorkItem?
    private let log = Logger(subsystem: "com.tinymuesli.tinyMuesli", category: "mic")

    /// Told when capture stopped and was restarted (or couldn't be). On the main thread.
    public var onEvent: ((MicEvent) -> Void)?

    public init() {}

    public var secondsWritten: Double { track?.seconds ?? 0 }
    public var writeError: Error? { track?.writer.lastError }

    /// While muted the mic stays open but the track records silence, so nothing said is kept or
    /// transcribed. Kept open rather than released so unmuting is instant and the call app's audio
    /// processing isn't disturbed.
    public var muted = false {
        didSet { track?.muted = muted }
    }

    public nonisolated static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(url: URL, clockStart: UInt64? = nil, speechDetector: SpeechDetectorFactory? = nil,
                      tee: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) throws {
        let format = try prepareInput()
        let track = try SegmentedTrack(url: url, inputFormat: format, clockStart: clockStart,
                                       speechDetector: speechDetector, tee: tee)
        track.muted = muted
        self.track = track
        try capture(format: format, into: track.writer)
        startMonitoring()
    }

    /// Releases the mic but keeps the track open, so `resume()` carries on in the same file.
    public func pause() {
        stopMonitoring()
        tearDownEngine()
    }

    /// The time paused becomes silence in the track. If the mic now has another sample rate (a
    /// different device), the track continues in a new file. Does nothing if the track never started.
    public func resume() throws {
        guard let track else { return }
        let format = try prepareInput()
        try capture(format: format, into: track.writer(resumingWith: format))
        startMonitoring()
    }

    /// `endingAt`: when the recording ended (host time); if the mic had stopped delivering audio
    /// before then, the track is padded with silence up to it.
    public func stop(endingAt end: UInt64? = nil) {
        pause()
        track?.close(endingAt: end)
    }

    // MARK: - Capture

    private func prepareInput() throws -> AVAudioFormat {
        engineUsed = true
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // By default voice processing ducks all other audio, which would turn the meeting down.
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        return input.outputFormat(forBus: 0)
    }

    private func capture(format: AVAudioFormat, into writer: TrackWriter) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "The microphone has no usable input format (\(format))"])
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format,
                                    block: Self.tapBlock(writing: writer, heartbeat: heartbeat))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        heartbeat.beat()  // the watchdog counts from here until the first buffer
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputMayHaveChanged(.configurationChanged) }
        }
    }

    /// Stops the engine and replaces it: one that has been through a device change can't be relied
    /// on to start again, so every (re)start gets a fresh one.
    private func tearDownEngine() {
        pendingCheck?.cancel()
        pendingCheck = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard engineUsed else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        engineUsed = false
    }

    /// Built in a nonisolated static context so the block never inherits an actor (it runs on the
    /// audio thread).
    private nonisolated static func tapBlock(writing writer: TrackWriter, heartbeat: Heartbeat) -> AVAudioNodeTapBlock {
        { @Sendable buffer, when in
            heartbeat.beat()
            writer.write(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil)
        }
    }

    // MARK: - Recovery

    /// Watches for input changes and stalls while capturing.
    private func startMonitoring() {
        capturing = true
        watchdog = MicWatchdog()
        if inputListener == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.inputMayHaveChanged(.defaultInputChanged) }
            }
            var address = Self.defaultInputAddress
            if AudioObjectAddPropertyListenerBlock(.system, &address, .main, listener) == noErr {
                inputListener = listener
            }
        }
        if watchdogTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.checkForStall() }
            }
            timer.activate()
            watchdogTimer = timer
        }
    }

    private func stopMonitoring() {
        capturing = false
        watchdogTimer?.cancel()
        watchdogTimer = nil
        if let inputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(.system, &address, .main, inputListener)
        }
        inputListener = nil
    }

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Changes come in bursts (output, input, aggregate rebuilt...), so look once things settle.
    /// Voice processing sometimes follows the new default input by itself; then audio is still
    /// arriving and nothing needs doing. Otherwise capture is rebuilt on the new input.
    private func inputMayHaveChanged(_ reason: MicEvent.Reason) {
        guard capturing else { return }
        log.notice("Mic input may have changed (\(reason.rawValue, privacy: .public))")
        pendingCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.capturing else { return }
                if self.engine.isRunning, self.heartbeat.secondsSinceLastBeat < MicWatchdog.healthySeconds {
                    self.log.notice("Mic still capturing after the change")
                } else {
                    self.restart(reason)
                }
            }
        }
        pendingCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + MicWatchdog.settleSeconds, execute: check)
    }

    private func checkForStall() {
        guard capturing else { return }
        let silent = heartbeat.secondsSinceLastBeat
        if silent < MicWatchdog.stallSeconds { return watchdog.recovered() }
        guard watchdog.shouldRestart(silentFor: silent, now: Heartbeat.now) else { return }
        log.error("Mic delivered no audio for \(silent, format: .fixed(precision: 1), privacy: .public) s; restarting capture")
        restart(.stalled)
    }

    /// Rebuilds capture on whatever the input is now, continuing the same track.
    private func restart(_ reason: MicEvent.Reason) {
        guard capturing, let track else { return }
        let silent = heartbeat.secondsSinceLastBeat
        watchdog.attempted(at: Heartbeat.now)
        tearDownEngine()
        do {
            let format = try prepareInput()
            try capture(format: format, into: track.writer(resumingWith: format))
            let device = Self.defaultInputName()
            log.notice("Mic capture restarted (\(reason.rawValue, privacy: .public)) on \(device ?? "?", privacy: .public) at \(Int(format.sampleRate)) Hz after \(silent, format: .fixed(precision: 1), privacy: .public) s without audio")
            onEvent?(.restarted(reason: reason, silentSeconds: silent, device: device))
        } catch {
            tearDownEngine()
            log.error("Mic capture couldn't restart (\(reason.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)")
            onEvent?(.restartFailed(reason: reason, silentSeconds: silent, error: error))
        }
    }

    private static func defaultInputName() -> String? {
        guard let device = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID.unknown),
              device != .unknown
        else { return nil }
        return try? device.readString(kAudioObjectPropertyName)
    }
}

/// Something that happened to mic capture during a recording.
public enum MicEvent: Sendable {
    public enum Reason: String, Sendable {
        /// AVAudioEngine reported a configuration change (it stops itself when this happens).
        case configurationChanged = "engine configuration changed"
        /// The system's default input device changed.
        case defaultInputChanged = "default input changed"
        /// No audio arrived for a while, for no reason we were told about.
        case stalled = "no audio arriving"
    }

    /// Capture runs again. `silentSeconds`: how long no audio had arrived before (now silence in the track).
    case restarted(reason: Reason, silentSeconds: Double, device: String?)
    /// Capture couldn't be restarted; the watchdog tries again later.
    case restartFailed(reason: Reason, silentSeconds: Double, error: Error)
}

/// When to restart mic capture that has stopped delivering audio, backing off while it keeps failing.
struct MicWatchdog {
    /// No audio for this long while capturing means capture has stalled. Buffers normally arrive
    /// every ~85 ms (4096 frames at 48 kHz), and even at 8 kHz every ~0.5 s.
    static let stallSeconds = 3.0
    /// Audio this recent means capture is fine.
    static let healthySeconds = 0.5
    /// How long to let a burst of device changes settle before checking.
    static let settleSeconds = 0.5
    static let maxBackoffSeconds = 30.0

    private var lastAttempt: Double?
    /// Restarts since audio last arrived.
    private var attempts = 0

    /// Waits longer between attempts while they don't bring audio back: 3, 6, 12, 24, 30, 30... s.
    var backoff: Double { min(Self.maxBackoffSeconds, Self.stallSeconds * pow(2, Double(max(0, attempts - 1)))) }

    /// `now` in seconds on any monotonic clock.
    func shouldRestart(silentFor silent: Double, now: Double) -> Bool {
        guard silent >= Self.stallSeconds else { return false }
        guard let lastAttempt else { return true }
        return now - lastAttempt >= backoff
    }

    /// A restart was tried (whether or not it threw: one that starts may still deliver nothing).
    mutating func attempted(at now: Double) {
        lastAttempt = now
        attempts += 1
    }

    /// Audio is arriving again.
    mutating func recovered() {
        lastAttempt = nil
        attempts = 0
    }
}

/// When the tap last delivered audio; written on the audio thread, read on main.
final class Heartbeat: Sendable {
    private let last = Atomic<UInt64>(mach_absolute_time())

    func beat() { last.store(mach_absolute_time(), ordering: .relaxed) }

    var secondsSinceLastBeat: Double {
        let now = mach_absolute_time(), then = last.load(ordering: .relaxed)
        return now > then ? Double(AudioConvertHostTimeToNanos(now - then)) / 1e9 : 0
    }

    /// Seconds on the host clock.
    static var now: Double { Double(AudioConvertHostTimeToNanos(mach_absolute_time())) / 1e9 }
}
