import SwiftUI
import RoomPlan
import ARKit

/// Wrapper SwiftUI di RoomCaptureView (UIKit) con supporto multi-stanza.
/// Permette di scansionare N stanze consecutive che vengono auto-allineate
/// nel coordinate system finale (CapturedStructure).
struct RoomCaptureSheetView: UIViewControllerRepresentable {

    let onCompletion: (CapturedStructure) -> Void
    let onCancel: (() -> Void)
    let onError: ((String) -> Void)?

    init(onCompletion: @escaping (CapturedStructure) -> Void,
         onCancel: @escaping () -> Void,
         onError: ((String) -> Void)? = nil) {
        self.onCompletion = onCompletion
        self.onCancel = onCancel
        self.onError = onError
    }

    func makeUIViewController(context: Context) -> MultiRoomCaptureContainerViewController {
        let vc = MultiRoomCaptureContainerViewController()
        vc.onCompletion = onCompletion
        vc.onCancel = onCancel
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: MultiRoomCaptureContainerViewController, context: Context) {}
}

/// ViewController che gestisce una sessione RoomCapture multi-stanza.
/// Usa SOLO RoomCaptureSessionDelegate (non RoomCaptureViewDelegate) per
/// evitare il conflitto che impedisce la chiamata di didEndWith.
final class MultiRoomCaptureContainerViewController: UIViewController, RoomCaptureSessionDelegate {

    var onCompletion: ((CapturedStructure) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((String) -> Void)?

    private var roomCaptureView: RoomCaptureView!
    private var captureSessionConfig = RoomCaptureSession.Configuration()
    private let roomBuilder = RoomBuilder(options: [.beautifyObjects])
    private let structureBuilder = StructureBuilder(options: [.beautifyObjects])

    /// Le CapturedRoom processate fin qui (una per stanza scansionata).
    private var capturedRooms: [CapturedRoom] = []

    private var isSessionRunning = false

    /// Catturato al momento del tap per evitare race condition con Task async.
    private var pendingAction: SessionEndAction = .none

    private enum SessionEndAction {
        case none
        case continueToNextRoom
        case finishAll
    }

    private var doneButton: UIButton!
    private var continueButton: UIButton!
    private var cancelButton: UIButton!
    private var roomCountLabel: UILabel!
    private var processingOverlay: UIView!
    private var processingLabel: UILabel!

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupRoomCaptureView()
        setupOverlayUI()
        setupProcessingOverlay()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isSessionRunning {
            stopSessionQuietly()
        }
    }

    // MARK: - Setup

    private func setupRoomCaptureView() {
        roomCaptureView = RoomCaptureView(frame: view.bounds)
        // Solo session delegate — NON impostiamo roomCaptureView.delegate
        // per evitare il conflitto con RoomCaptureViewDelegate
        roomCaptureView.captureSession.delegate = self
        roomCaptureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(roomCaptureView)
    }

    private func setupOverlayUI() {
        // Label "Stanza N"
        roomCountLabel = UILabel()
        roomCountLabel.text = "Stanza 1"
        roomCountLabel.textColor = .white
        roomCountLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        roomCountLabel.textAlignment = .center
        roomCountLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        roomCountLabel.layer.cornerRadius = 14
        roomCountLabel.layer.masksToBounds = true
        roomCountLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(roomCountLabel)

        // Cancel button
        cancelButton = UIButton(type: .system)
        var cancelConfig = UIButton.Configuration.tinted()
        cancelConfig.title = "Annulla"
        cancelConfig.baseBackgroundColor = UIColor.white.withAlphaComponent(0.2)
        cancelConfig.baseForegroundColor = .white
        cancelConfig.cornerStyle = .capsule
        cancelConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        cancelButton.configuration = cancelConfig
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancelButton)

        // Continue button
        continueButton = UIButton(type: .system)
        var continueConfig = UIButton.Configuration.filled()
        continueConfig.title = "Continua in altra stanza"
        continueConfig.image = UIImage(systemName: "arrow.right.circle.fill")
        continueConfig.imagePadding = 6
        continueConfig.imagePlacement = .leading
        continueConfig.baseBackgroundColor = UIColor.white.withAlphaComponent(0.95)
        continueConfig.baseForegroundColor = UIColor(red: 0.95, green: 0.30, blue: 0.25, alpha: 1.0)
        continueConfig.cornerStyle = .capsule
        continueConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 22)
        continueButton.configuration = continueConfig
        continueButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        view.addSubview(continueButton)

        // Done button
        doneButton = UIButton(type: .system)
        var doneConfig = UIButton.Configuration.filled()
        doneConfig.title = "Fine"
        doneConfig.image = UIImage(systemName: "checkmark.circle.fill")
        doneConfig.imagePadding = 6
        doneConfig.imagePlacement = .leading
        doneConfig.baseBackgroundColor = UIColor(red: 0.95, green: 0.30, blue: 0.25, alpha: 1.0)
        doneConfig.baseForegroundColor = .white
        doneConfig.cornerStyle = .capsule
        doneConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
        doneButton.configuration = doneConfig
        doneButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        view.addSubview(doneButton)

        // Constraint
        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),

            roomCountLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            roomCountLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            roomCountLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            roomCountLabel.heightAnchor.constraint(equalToConstant: 28),

            continueButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            continueButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),

            doneButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            doneButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
        ])

        setActionButtonsEnabled(false)
    }

    private func setupProcessingOverlay() {
        processingOverlay = UIView()
        processingOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        processingOverlay.translatesAutoresizingMaskIntoConstraints = false
        processingOverlay.isHidden = true

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        processingLabel = UILabel()
        processingLabel.text = "Elaborazione scansione…"
        processingLabel.textColor = .white
        processingLabel.font = .systemFont(ofSize: 15, weight: .medium)
        processingLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [spinner, processingLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        processingOverlay.addSubview(stack)
        view.addSubview(processingOverlay)

        NSLayoutConstraint.activate([
            processingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            processingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            processingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            processingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: processingOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: processingOverlay.centerYAnchor),
        ])
    }

    private func setActionButtonsEnabled(_ enabled: Bool) {
        continueButton.isEnabled = enabled
        doneButton.isEnabled = enabled
        let alpha: CGFloat = enabled ? 1.0 : 0.5
        continueButton.alpha = alpha
        doneButton.alpha = alpha
    }

    private func updateRoomCountLabel() {
        let count = capturedRooms.count
        roomCountLabel.text = "Stanza \(count + 1)"
    }

    private func showProcessing(message: String) {
        processingLabel.text = message
        processingOverlay.isHidden = false
        setActionButtonsEnabled(false)
        cancelButton.isEnabled = false
    }

    private func hideProcessing() {
        processingOverlay.isHidden = true
        cancelButton.isEnabled = true
    }

    // MARK: - Session control

    private func startSession() {
        roomCaptureView.captureSession.run(configuration: captureSessionConfig)
        isSessionRunning = true
    }

    private func stopSession() {
        roomCaptureView.captureSession.stop()
        isSessionRunning = false
    }

    /// Stop silenzioso usato nel teardown (viewWillDisappear) per non triggerare il delegate.
    private func stopSessionQuietly() {
        isSessionRunning = false
        roomCaptureView.captureSession.stop()
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        pendingAction = .none
        stopSessionQuietly()
        onCancel?()
    }

    @objc private func continueTapped() {
        // Cattura il valore ora, prima dell'async, per evitare race condition
        pendingAction = .continueToNextRoom
        setActionButtonsEnabled(false)
        stopSession()
    }

    @objc private func doneTapped() {
        // Cattura il valore ora, prima dell'async, per evitare race condition
        pendingAction = .finishAll
        setActionButtonsEnabled(false)
        stopSession()
    }

    // MARK: - RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        DispatchQueue.main.async {
            if !self.continueButton.isEnabled {
                self.setActionButtonsEnabled(true)
            }
        }
    }

    func captureSession(_ session: RoomCaptureSession,
                        didEndWith data: CapturedRoomData,
                        error: Error?) {
        dprint("✅ [RoomCapture] captureSession didEndWith chiamato. pendingAction=\(pendingAction), error=\(String(describing: error))")

        if let error {
            dprint("⚠️ [RoomCapture] Errore sessione: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.hideProcessing()
                self.onError?("Errore durante la scansione: \(error.localizedDescription)")
                self.onCancel?()
            }
            return
        }

        // Cattura l'azione corrente immediatamente (evita race condition)
        let action = self.pendingAction

        // Se l'azione è .none, significa teardown silenzioso — non fare nulla
        guard action != .none else { return }

        DispatchQueue.main.async {
            self.showProcessing(message: "Elaborazione stanza…")
        }

        Task {
            do {
                dprint("✅ [RoomCapture] Inizio roomBuilder.capturedRoom...")
                let room = try await roomBuilder.capturedRoom(from: data)
                dprint("✅ [RoomCapture] Room elaborata con \(room.walls.count) muri, \(room.doors.count) porte")

                await MainActor.run {
                    self.capturedRooms.append(room)
                    self.hideProcessing()

                    switch action {
                    case .finishAll:
                        self.showProcessing(message: "Costruzione planimetria…")
                        self.buildStructure()
                    case .continueToNextRoom:
                        self.updateRoomCountLabel()
                        self.recreateRoomCaptureView()
                    case .none:
                        break
                    }
                }
            } catch {
                dprint("⚠️ [RoomCapture] roomBuilder fallito: \(error.localizedDescription)")
                await MainActor.run {
                    self.hideProcessing()
                    self.onError?("Impossibile elaborare la stanza scansionata.\n\(error.localizedDescription)")
                    self.onCancel?()
                }
            }
        }
    }

    // MARK: - Multi-room flow

    /// Distrugge il RoomCaptureView corrente e ne crea uno fresco.
    /// Necessario per evitare crash CoreMotion quando si riavvia una nuova sessione.
    private func recreateRoomCaptureView() {
        roomCaptureView?.removeFromSuperview()
        roomCaptureView = nil
        pendingAction = .none

        setupRoomCaptureView()

        // Riporta i bottoni overlay sopra la nuova capture view
        view.bringSubviewToFront(cancelButton)
        view.bringSubviewToFront(roomCountLabel)
        view.bringSubviewToFront(continueButton)
        view.bringSubviewToFront(doneButton)
        view.bringSubviewToFront(processingOverlay)

        startSession()
    }

    private func buildStructure() {
        guard !capturedRooms.isEmpty else {
            dprint("⚠️ [RoomCapture] Nessuna stanza catturata, impossibile costruire la struttura")
            hideProcessing()
            onError?("Nessuna stanza acquisita correttamente. Riprova la scansione.")
            onCancel?()
            return
        }

        dprint("✅ [RoomCapture] buildStructure con \(capturedRooms.count) stanze")

        Task {
            do {
                let structure = try await structureBuilder.capturedStructure(from: capturedRooms)
                dprint("✅ [RoomCapture] CapturedStructure creata: \(structure.rooms.count) stanze")
                await MainActor.run {
                    self.hideProcessing()
                    self.onCompletion?(structure)
                }
            } catch {
                dprint("⚠️ [RoomCapture] structureBuilder fallito: \(error.localizedDescription)")
                await MainActor.run {
                    self.hideProcessing()
                    // Se c'è una sola stanza, proviamo a costruire una struttura da quella sola
                    if self.capturedRooms.count == 1 {
                        self.buildStructureFromSingleRoom()
                    } else {
                        self.onError?("Impossibile allineare le stanze scansionate. Assicurati di scansionare stanze adiacenti con aree sovrapposte.\n\nDettaglio: \(error.localizedDescription)")
                        self.onCancel?()
                    }
                }
            }
        }
    }

    /// Fallback: se la struttura multi-stanza fallisce e c'è una sola stanza,
    /// costruisce una CapturedStructure da quella sola tramite StructureBuilder.
    private func buildStructureFromSingleRoom() {
        guard let singleRoom = capturedRooms.first else {
            onCancel?()
            return
        }

        dprint("✅ [RoomCapture] Tentativo fallback con singola stanza (\(singleRoom.walls.count) muri)")
        showProcessing(message: "Generazione planimetria singola stanza…")

        Task {
            do {
                let structure = try await structureBuilder.capturedStructure(from: [singleRoom])
                await MainActor.run {
                    self.hideProcessing()
                    self.onCompletion?(structure)
                }
            } catch {
                dprint("⚠️ [RoomCapture] Fallback singola stanza fallito: \(error.localizedDescription)")
                await MainActor.run {
                    self.hideProcessing()
                    self.onError?("Scansione non riuscita. Riprova camminando lentamente attorno a tutta la stanza.\n\nDettaglio: \(error.localizedDescription)")
                    self.onCancel?()
                }
            }
        }
    }
}

/// Helper statico per verificare se il device supporta RoomPlan.
enum RoomPlanSupport {
    static var isSupported: Bool {
        RoomCaptureSession.isSupported
    }
}
