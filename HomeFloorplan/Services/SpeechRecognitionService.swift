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

    enum SpeechRecognitionError: LocalizedError {
        case alreadyRecording
        case permissionsDenied
        case recognizerUnavailable
        case audioInputUnavailable
        case startFailed(Error)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return String(localized: "speech.error.alreadyRecording", defaultValue: "Recording is already active.")
            case .permissionsDenied:
                return String(localized: "speech.error.permissionsDenied", defaultValue: "Microphone or speech recognition permission is disabled.")
            case .recognizerUnavailable:
                return String(localized: "speech.error.recognizerUnavailable", defaultValue: "Speech recognition is currently unavailable.")
            case .audioInputUnavailable:
                return String(localized: "speech.error.audioInputUnavailable", defaultValue: "No usable microphone input is available.")
            case .startFailed(let error):
                return error.localizedDescription
            }
        }
    }

    // MARK: - Observed state

    private(set) var isRecording:     Bool            = false
    private(set) var transcript:      String          = ""
    private(set) var permissionState: PermissionState = .undetermined
    private(set) var errorMessage:    String?

    var isAvailable: Bool { recognizer?.isAvailable == true }

    // MARK: - Private

    private let recognizer:      SFSpeechRecognizer?
    private var recognitionReq:  SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "com.homefloorplan.speech.audio", qos: .userInitiated)
    private var hasInstalledTap = false
    private var isStarting = false

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
    }

    // MARK: - Recording

    func startRecording() async throws {
        guard permissionState == .authorized else { throw SpeechRecognitionError.permissionsDenied }
        guard let recognizer, recognizer.isAvailable else { throw SpeechRecognitionError.recognizerUnavailable }

        transcript = ""
        errorMessage = nil
        isRecording = true

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                audioQueue.async { [weak self] in
                    guard let self else {
                        cont.resume(throwing: SpeechRecognitionError.recognizerUnavailable)
                        return
                    }

                    guard !self.isStarting, !self.audioEngine.isRunning else {
                        cont.resume(throwing: SpeechRecognitionError.alreadyRecording)
                        return
                    }

                    self.isStarting = true
                    self.cleanupOnAudioQueue(deactivateSession: false)

                    do {
                        self.recognitionReq = request

                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
                        try session.setActive(true, options: .notifyOthersOnDeactivation)

                        let node = self.audioEngine.inputNode
                        let format = node.outputFormat(forBus: 0)
                        guard format.sampleRate > 0, format.channelCount > 0 else {
                            throw SpeechRecognitionError.audioInputUnavailable
                        }

                        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                            request.append(buffer)
                        }
                        self.hasInstalledTap = true

                        self.audioEngine.prepare()
                        try self.audioEngine.start()
                        self.isStarting = false
                        cont.resume()
                    } catch let speechError as SpeechRecognitionError {
                        self.isStarting = false
                        self.cleanupOnAudioQueue(deactivateSession: true)
                        cont.resume(throwing: speechError)
                    } catch {
                        self.isStarting = false
                        self.cleanupOnAudioQueue(deactivateSession: true)
                        cont.resume(throwing: SpeechRecognitionError.startFailed(error))
                    }
                }
            }

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || result?.isFinal == true {
                        self.stopRecording()
                    }
                }
            }
        } catch {
            isRecording = false
            throw error
        }
    }

    func stopRecording() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.isStarting = false
            self.cleanupOnAudioQueue(deactivateSession: true)
            DispatchQueue.main.async { [weak self] in
                self?.isRecording = false
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func setError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func cleanupOnAudioQueue(deactivateSession: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        recognitionReq?.endAudio()
        recognitionReq = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - SFSpeechRecognizerDelegate

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !available && self.isRecording {
                self.stopRecording()
            }
        }
    }
}
