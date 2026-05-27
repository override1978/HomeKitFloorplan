import SwiftUI
import RoomPlan
import ARKit

/// Wrapper SwiftUI di RoomCaptureView (UIKit) con supporto multi-stanza.
/// Permette di scansionare N stanze consecutive che vengono auto-allineate
/// nel coordinate system finale (CapturedStructure).
struct RoomCaptureSheetView: UIViewControllerRepresentable {
    
    let onCompletion: (CapturedStructure) -> Void
    let onCancel: () -> Void
    
    func makeUIViewController(context: Context) -> MultiRoomCaptureContainerViewController {
        let vc = MultiRoomCaptureContainerViewController()
        vc.onCompletion = onCompletion
        vc.onCancel = onCancel
        return vc
    }
    
    func updateUIViewController(_ uiViewController: MultiRoomCaptureContainerViewController, context: Context) {}
}

/// ViewController che gestisce una sessione RoomCapture multi-stanza.
final class MultiRoomCaptureContainerViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    
    var onCompletion: ((CapturedStructure) -> Void)?
    var onCancel: (() -> Void)?
    
    private var roomCaptureView: RoomCaptureView!
    private var captureSessionConfig = RoomCaptureSession.Configuration()
    private let roomBuilder = RoomBuilder(options: [.beautifyObjects])
    private let structureBuilder = StructureBuilder(options: [.beautifyObjects])
    
    /// Le CapturedRoom processate fin qui (una per stanza scansionata).
    private var capturedRooms: [CapturedRoom] = []
    
    private var isSessionRunning = false
    private var isFinishing = false
    
    private var doneButton: UIButton!
    private var continueButton: UIButton!
    private var cancelButton: UIButton!
    private var roomCountLabel: UILabel!
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupRoomCaptureView()
        setupOverlayUI()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isSessionRunning {
            stopSession()
        }
    }
    
    // MARK: - Setup
    
    private func setupRoomCaptureView() {
        roomCaptureView = RoomCaptureView(frame: view.bounds)
        roomCaptureView.captureSession.delegate = self
        roomCaptureView.delegate = self
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
    
    // MARK: - Session control
    
    private func startSession() {
        roomCaptureView.captureSession.run(configuration: captureSessionConfig)
        isSessionRunning = true
    }
    
    private func stopSession() {
        roomCaptureView.captureSession.stop()
        isSessionRunning = false
    }
    
    // MARK: - Actions
    
    @objc private func cancelTapped() {
        stopSession()
        onCancel?()
    }

    @objc private func continueTapped() {
        isFinishing = false
        stopSession()
    }

    @objc private func doneTapped() {
        isFinishing = true
        stopSession()
    }
    
    // MARK: - RoomCaptureViewDelegate
    
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        return false  // gestiamo noi il flow multi-stanza
    }
    
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        // non chiamata
    }
    
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        // Quando arrivano i primi dati, abilita i bottoni di fine
        DispatchQueue.main.async {
            if !self.continueButton.isEnabled {
                self.setActionButtonsEnabled(true)
            }
        }
    }
    
    // MARK: - RoomCaptureSessionDelegate
    
    func captureSession(_ session: RoomCaptureSession,
                        didEndWith data: CapturedRoomData,
                        error: Error?) {
        if let error {
            print("⚠️ Capture session ended with error: \(error.localizedDescription)")
        }
        
        Task {
            do {
                let room = try await roomBuilder.capturedRoom(from: data)
                await MainActor.run {
                    self.capturedRooms.append(room)
                    
                    if self.isFinishing {
                        self.buildStructure()
                    } else {
                        self.updateRoomCountLabel()
                        self.setActionButtonsEnabled(false)
                        self.recreateRoomCaptureView()    // 👈 ricrea da capo
                    }
                }
            } catch {
                print("⚠️ Failed to process CapturedRoomData: \(error.localizedDescription)")
                await MainActor.run {
                    self.onCancel?()
                }
            }
        }
    }
    
    /// Distrugge il RoomCaptureView corrente e ne crea uno fresco.
    /// Necessario per evitare crash CoreMotion quando si riavvia una nuova sessione.
    private func recreateRoomCaptureView() {
        // Rimuovi il vecchio
        roomCaptureView?.removeFromSuperview()
        roomCaptureView = nil
        
        // Crea il nuovo
        setupRoomCaptureView()
        
        // Riporta i bottoni overlay sopra
        view.bringSubviewToFront(cancelButton)
        view.bringSubviewToFront(roomCountLabel)
        view.bringSubviewToFront(continueButton)
        view.bringSubviewToFront(doneButton)
        
        // Avvia sessione sul nuovo
        startSession()
    }
    
    private func buildStructure() {
        Task {
            do {
                let structure = try await structureBuilder.capturedStructure(from: capturedRooms)
                await MainActor.run {
                    self.onCompletion?(structure)
                }
            } catch {
                print("⚠️ Failed to build CapturedStructure: \(error.localizedDescription)")
                await MainActor.run {
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
