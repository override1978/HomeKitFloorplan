import Foundation
@preconcurrency import Speech
import AVFoundation
import Observation

/// Real-time streaming speech-to-text service using SFSpeechRecognizer + AVAudioEngine.
/// Designed to be held as @State in ChatBotView.
/// Call requestPermissionsIfNeeded() on first use, then startRecording() / stopRecording().
@Observable
final class SpeechRecognitionService: NSObject, SFSpeechRecognizerDelegate {

    // MARK: - Types

    enum PermissionState { case undetermined, authorized, denied }

    // MARK: - Observed state

    private(set) var isRecording:     Bool            = false
    private(set) var transcript:      String          = ""
    private(set) var permissionState: PermissionState = .undetermined

    var isAvailable: Bool { recognizer?.isAvailable == true }

    // MARK: - Private

    private let recognizer:      SFSpeechRecognizer?
    private var recognitionReq:  SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var didPreWarm = false

    // MARK: - Init

    override init() {
        // Locale.preferredLanguages gives BCP-47 identifiers (e.g. "it-IT") which
        // SFSpeechRecognizer requires. Locale.current uses underscores ("it_IT") and
        // can silently fall back to English.
        recognizer = Locale.preferredLanguages
            .lazy
            .compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
            .first ?? SFSpeechRecognizer()
        super.init()
        recognizer?.delegate = self
        refreshPermissionState()
        if permissionState == .authorized {
            didPreWarm = true
            preWarmAudio()
        }
    }

    // MARK: - Permissions

    private func refreshPermissionState() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micPermission = AVAudioApplication.shared.recordPermission
        switch speechStatus {
        case .authorized:
            permissionState = micPermission == .granted ? .authorized : .undetermined
        case .denied, .restricted:
            permissionState = .denied
        default:
            permissionState = micPermission == .denied ? .denied : .undetermined
        }
    }

    func requestPermissionsIfNeeded() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
            }
        }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                AVAudioApplication.requestRecordPermission { _ in cont.resume() }
            }
        }
        refreshPermissionState()
        if permissionState == .authorized && !didPreWarm {
            didPreWarm = true
            preWarmAudio()
        }
    }

    /// Pre-warms both audio hardware and the on-device speech model so the first mic tap is instant.
    private func preWarmAudio() {
        // Audio hardware: setActive blocks ~100-400 ms — keep it off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try? session.setActive(true, options: .notifyOthersOnDeactivation)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        // Speech model: recognitionTask(with:) must run on main actor. First call loads
        // the model (~200-500 ms). Create and immediately cancel a dummy task here so
        // the model is resident by the time the user taps the mic.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let req = SFSpeechAudioBufferRecognitionRequest()
            let t = self.recognizer?.recognitionTask(with: req) { _, _ in }
            t?.cancel()
            req.endAudio()
        }
    }

    // MARK: - Recording

    func startRecording() async throws {
        recognitionTask?.cancel(); recognitionTask = nil
        recognitionReq?.endAudio(); recognitionReq = nil
        transcript = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        recognitionReq = req

        // All audio setup on a background queue:
        // • AVAudioSession.setActive() blocks ~100-400 ms
        // • inputNode first access initialises hardware (~50-200 ms on first call)
        // • AVAudioEngine.start() is also blocking
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { cont.resume(); return }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                    try session.setActive(true, options: .notifyOthersOnDeactivation)
                    let node   = self.audioEngine.inputNode
                    let format = node.outputFormat(forBus: 0)
                    node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                        self?.recognitionReq?.append(buffer)
                    }
                    self.audioEngine.prepare()
                    try self.audioEngine.start()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // recognitionTask(with:) must run on main actor — first call loads the on-device
        // speech model; the pre-warm in preWarmAudio() ensures this has already happened
        // before the user taps the mic.
        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self.stopRecording() }
            }
        }
        isRecording = true
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionReq?.endAudio(); recognitionReq = nil
        recognitionTask?.cancel();  recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
    }

    // MARK: - SFSpeechRecognizerDelegate

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available && isRecording { stopRecording() }
    }
}
