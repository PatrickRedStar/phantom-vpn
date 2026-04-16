//
//  QRScannerView.swift
//  GhostStream
//
//  SwiftUI camera viewfinder that scans QR codes. On first valid detection
//  it calls `onScan(payload)` and dismisses the sheet.
//

import SwiftUI
import AVFoundation
import UIKit

/// SwiftUI wrapper over `QRScannerViewController`. Present via `.sheet`
/// from Settings; on scan, the completion handler receives the raw QR
/// payload string.
public struct QRScannerView: UIViewControllerRepresentable {

    /// Called on the first valid QR code. The view controller self-dismisses.
    public let onScan: (String) -> Void
    /// Called when the user cancels (top-bar button).
    public let onCancel: () -> Void

    public init(onScan: @escaping (String) -> Void, onCancel: @escaping () -> Void = {}) {
        self.onScan = onScan
        self.onCancel = onCancel
    }

    public func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        vc.onCancel = onCancel
        return vc
    }

    public func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        // No-op: state lives in the UIViewController.
    }
}

// MARK: - UIViewController

/// Camera-backed QR scanner. Requests `AVCaptureDevice` camera permission,
/// sets up a `AVCaptureSession` with a `AVCaptureMetadataOutput` filtered to
/// the `.qr` object type, and reports the first valid string payload via
/// `onScan`.
///
/// UX: a thin crosshair overlay in the palette `signal` color. A cancel
/// button in the top-right dismisses via `onCancel`.
public final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    /// Invoked with the scanned payload string. Self-dismisses after.
    public var onScan: ((String) -> Void)?
    /// Invoked when the user taps the cancel button.
    public var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didReportResult = false
    private var permissionLabel: UILabel?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCancelButton()
        requestAccessAndStart()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning && session.inputs.count > 0 {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - Setup

    private func setupCancelButton() {
        let btn = UIButton(type: .system)
        btn.setTitle("ОТМЕНА", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            btn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    @objc private func cancelTapped() {
        onCancel?()
        dismiss(animated: true)
    }

    private func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.configureSession() }
                    else { self.showPermissionDenied() }
                }
            }
        case .denied, .restricted:
            showPermissionDenied()
        @unknown default:
            showPermissionDenied()
        }
    }

    private func showPermissionDenied() {
        let label = UILabel()
        label.text = "Доступ к камере запрещён.\nРазрешите в настройках."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        permissionLabel = label
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            showPermissionDenied()
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) { session.addOutput(output) }
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            session.commitConfiguration()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            self.previewLayer = layer

            installCrosshair()

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        } catch {
            showPermissionDenied()
        }
    }

    private func installCrosshair() {
        let overlay = QRCrosshairView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // signal lime — match the dark palette signal directly (the
        // SwiftUI palette isn't available inside the UIKit layer).
        overlay.strokeColor = UIColor(red: 0xC4/255.0, green: 0xFF/255.0, blue: 0x3E/255.0, alpha: 1)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didReportResult else { return }
        for obj in metadataObjects {
            guard let readable = obj as? AVMetadataMachineReadableCodeObject,
                  readable.type == .qr,
                  let string = readable.stringValue, !string.isEmpty
            else { continue }
            didReportResult = true
            session.stopRunning()
            onScan?(string)
            dismiss(animated: true)
            return
        }
    }
}

// MARK: - Crosshair overlay

/// Minimal crosshair / corner-frame overlay drawn over the camera preview.
private final class QRCrosshairView: UIView {
    var strokeColor: UIColor = .white

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let side = min(rect.width, rect.height) * 0.6
        let box = CGRect(
            x: (rect.width - side) / 2,
            y: (rect.height - side) / 2,
            width: side, height: side
        )
        let corner: CGFloat = 28
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.square)

        // Top-left
        ctx.move(to: CGPoint(x: box.minX, y: box.minY + corner))
        ctx.addLine(to: CGPoint(x: box.minX, y: box.minY))
        ctx.addLine(to: CGPoint(x: box.minX + corner, y: box.minY))
        // Top-right
        ctx.move(to: CGPoint(x: box.maxX - corner, y: box.minY))
        ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY + corner))
        // Bottom-right
        ctx.move(to: CGPoint(x: box.maxX, y: box.maxY - corner))
        ctx.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        ctx.addLine(to: CGPoint(x: box.maxX - corner, y: box.maxY))
        // Bottom-left
        ctx.move(to: CGPoint(x: box.minX + corner, y: box.maxY))
        ctx.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        ctx.addLine(to: CGPoint(x: box.minX, y: box.maxY - corner))
        ctx.strokePath()
    }
}

#if DEBUG
struct QRScannerView_Previews: PreviewProvider {
    static var previews: some View {
        QRScannerView(onScan: { _ in }, onCancel: {})
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Camera preview — simulator shows black screen")
    }
}
#endif
