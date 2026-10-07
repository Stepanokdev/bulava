import UIKit
import AVFoundation

/// Reads the pairing code off the Mac's screen. Decoded on the phone; the camera stops the moment
/// this screen goes.
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onResult: (String?) -> Void
    private var delivered = false
    private let hint = UILabel()
    private let denied = UIStackView()

    init(onResult: @escaping (String?) -> Void) {
        self.onResult = onResult
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layoutChrome()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.startCamera() : self.showDenied() }
            }
        default: showDenied()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
        if !delivered { delivered = true; onResult(nil) }
    }

    private func startCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            showDenied()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
            .first(where: { $0.contains("#") }) else { return }
        delivered = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        session.stopRunning()
        onResult(code)
        dismiss(animated: true)
    }

    private func layoutChrome() {
        let frame = UIView()
        frame.layer.borderColor = UIColor(red: 0.78, green: 0.945, blue: 0.514, alpha: 1).cgColor
        frame.layer.borderWidth = 2
        frame.layer.cornerRadius = 20
        frame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frame)

        hint.text = NSLocalizedString("scan.hint", value: "Point the camera at the code on your Mac", comment: "")
        hint.textColor = .white
        hint.font = .preferredFont(forTextStyle: .callout)
        hint.adjustsFontForContentSizeCategory = true
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .white
        close.accessibilityLabel = NSLocalizedString("scan.close", value: "Close", comment: "")
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)

        NSLayoutConstraint.activate([
            frame.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            frame.widthAnchor.constraint(equalToConstant: 260),
            frame.heightAnchor.constraint(equalToConstant: 260),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -48),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            close.widthAnchor.constraint(equalToConstant: 48),
            close.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func showDenied() {
        hint.text = NSLocalizedString("scan.denied", value: "Bulava needs the camera to read the code on your Mac. Allow it in Settings, or scan the code with the Camera app instead.", comment: "")
        let open = UIButton(type: .system)
        open.setTitle(NSLocalizedString("scan.settings", value: "Open Settings", comment: ""), for: .normal)
        open.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        open.tintColor = UIColor(red: 0.78, green: 0.945, blue: 0.514, alpha: 1)
        open.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        open.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(open)
        NSLayoutConstraint.activate([
            open.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            open.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -16),
            open.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
