@preconcurrency import AVFoundation
import SwiftUI

struct QRCodeScannerView: View {
    enum ScannerState: Equatable {
        case preparing
        case scanning
        case permissionDenied
        case cameraUnavailable
        case configurationFailed
        case invalidCode
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var state: ScannerState = .preparing
    @State private var attemptID = UUID()

    let onCode: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cameraShouldBeVisible {
                ScannerCamera(
                    onCode: handle,
                    onStateChange: { state = $0 }
                )
                .id(attemptID)
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel("关闭扫码")
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)

                Spacer()

                if cameraShouldBeVisible {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(state == .invalidCode ? KrisTheme.clay : .white, lineWidth: 3)
                        .frame(width: 252, height: 252)
                        .shadow(color: .black.opacity(0.35), radius: 18)
                        .accessibilityHidden(true)
                }

                Spacer()

                statusPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var cameraShouldBeVisible: Bool {
        state == .preparing || state == .scanning || state == .invalidCode
    }

    private var statusPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(state == .invalidCode ? KrisTheme.clay : KrisTheme.lime)
            Text(statusTitle)
                .font(.headline.weight(.bold))
            Text(statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if state == .permissionDenied {
                Button("打开相机权限设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(KrisPrimaryButtonStyle())
            } else if state == .cameraUnavailable || state == .configurationFailed {
                Button("重新尝试") { retry() }
                    .buttonStyle(KrisPrimaryButtonStyle())
            }

            Button("改用手动粘贴") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minHeight: 44)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var statusIcon: String {
        switch state {
        case .permissionDenied: "camera.fill"
        case .cameraUnavailable, .configurationFailed: "camera.metering.unknown"
        case .invalidCode: "qrcode"
        case .preparing: "camera.aperture"
        case .scanning: "qrcode.viewfinder"
        }
    }

    private var statusTitle: String {
        switch state {
        case .preparing: "正在准备相机"
        case .scanning: "扫描 Mac 配对码"
        case .permissionDenied: "需要相机权限"
        case .cameraUnavailable: "没有可用相机"
        case .configurationFailed: "相机启动失败"
        case .invalidCode: "这不是 Kris 配对码"
        }
    }

    private var statusMessage: String {
        switch state {
        case .preparing: "首次使用时，iPhone 会显示系统相机授权。"
        case .scanning: "把一次性二维码完整放入取景框；健康数据授权不需要此步骤。"
        case .permissionDenied: "请在系统设置中允许 Kris 使用相机，或返回设置页粘贴配对链接。"
        case .cameraUnavailable: "当前设备没有可供扫码使用的摄像头。"
        case .configurationFailed: "无法建立相机会话，请关闭其他相机应用后重试。"
        case .invalidCode: "请扫描由 Kris Mac companion 新生成、尚未过期的一次性二维码。"
        }
    }

    private func handle(_ code: String) {
        guard Self.isValidPairingCode(code) else {
            state = .invalidCode
            return
        }
        onCode(code)
    }

    private func retry() {
        state = .preparing
        attemptID = UUID()
    }

    static func isValidPairingCode(_ code: String) -> Bool {
        (try? PairingDescriptor(uri: code)) != nil
    }
}

private struct ScannerCamera: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onStateChange: (QRCodeScannerView.ScannerState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onStateChange: onStateChange)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: Coordinator) {
        uiViewController.stop()
    }

    final class Coordinator: NSObject, ScannerViewControllerDelegate {
        let onCode: (String) -> Void
        let onStateChange: (QRCodeScannerView.ScannerState) -> Void

        init(onCode: @escaping (String) -> Void, onStateChange: @escaping (QRCodeScannerView.ScannerState) -> Void) {
            self.onCode = onCode
            self.onStateChange = onStateChange
        }

        func scanner(_ scanner: ScannerViewController, found code: String) { onCode(code) }
        func scanner(_ scanner: ScannerViewController, changed state: QRCodeScannerView.ScannerState) { onStateChange(state) }
    }
}

private protocol ScannerViewControllerDelegate: AnyObject {
    func scanner(_ scanner: ScannerViewController, found code: String)
    func scanner(_ scanner: ScannerViewController, changed state: QRCodeScannerView.ScannerState)
}

private final class ScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ScannerViewControllerDelegate?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?
    private var lastDeliveryAt = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configure()
                    } else {
                        self.report(.permissionDenied)
                    }
                }
            }
        case .denied, .restricted:
            report(.permissionDenied)
        @unknown default:
            report(.configurationFailed)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            report(.cameraUnavailable)
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            report(.configurationFailed)
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            report(.configurationFailed)
            return
        }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            report(.configurationFailed)
            return
        }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            captureSession.startRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                self.report(.scanning)
            }
        }
    }

    private func report(_ state: QRCodeScannerView.ScannerState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.scanner(self, changed: state)
        }
    }

    func stop() {
        if session.isRunning {
            DispatchQueue.global(qos: .utility).async { [session] in session.stopRunning() }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue else { return }
        let now = Date()
        guard code != lastCode || now.timeIntervalSince(lastDeliveryAt) > 1.5 else { return }
        lastCode = code
        lastDeliveryAt = now
        delegate?.scanner(self, found: code)
    }
}
