import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// A topic's QR code holds its plain `https://<server>/<topic>` address. For ntfy-me.com the iPhone
/// Camera app opens that as a Universal Link; for any server, the Add sheet's scanner reads it back.
enum TopicQRCode {
    static func payload(baseUrl: String, topic: String) -> String {
        topicUrl(baseUrl: baseUrl, topic: topic)
    }

    /// Black modules on white with the standard four-module quiet zone, scaled by whole pixels so
    /// every module stays sharp. Medium error correction survives a scratched or dim screen.
    static func image(for payload: String, pixelsPerModule: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let scaled = code.transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct TopicQRCodeView: View {
    let baseUrl: String
    let topic: String
    @Binding var isShowing: Bool
    @State private var sharing = false

    private var payload: String { TopicQRCode.payload(baseUrl: baseUrl, topic: topic) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if let image = TopicQRCode.image(for: payload) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 300)
                            .padding(12)
                            // Always dark on light: scanners misread an inverted code in dark mode.
                            .background(Color.white)
                            .cornerRadius(12)
                            .accessibilityLabel("QR code for \(shortUrl(url: payload))")
                    }
                    Text(payload)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Label {
                        Text("Anyone who scans this code can subscribe to this topic and read its messages, "
                             + "unless the server requires a login. Share it only with people you trust.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.shield")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .navigationTitle("QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { isShowing = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        sharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
            }
            .sheet(isPresented: $sharing) {
                TopicQRShareSheet(items: [TopicQRCode.image(for: payload) as Any, URL(string: payload) as Any]
                    .compactMap { $0 })
            }
        }
    }
}

private struct TopicQRShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// What the scanner screen can show before it has a code.
enum TopicQRCameraState: Equatable {
    case scanning, needsPermission, denied, unavailable

    static func from(hasCamera: Bool, status: AVAuthorizationStatus) -> TopicQRCameraState {
        guard hasCamera else { return .unavailable }
        switch status {
        case .authorized: return .scanning
        case .notDetermined: return .needsPermission
        default: return .denied
        }
    }
}

/// Reads one topic QR code. `onCode` gets every decoded string and returns whether it was a topic
/// address; the caller closes this screen when it was.
struct TopicQRScannerView: View {
    @Binding var isShowing: Bool
    let onCode: (String) -> Bool
    @State private var state = TopicQRCameraState.from(
        hasCamera: AVCaptureDevice.default(for: .video) != nil,
        status: AVCaptureDevice.authorizationStatus(for: .video))
    @State private var rejected: String?
    @State private var accepted = false

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Scan QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { isShowing = false }
                    }
                }
        }
        .onAppear {
            if state == .needsPermission {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async { state = granted ? .scanning : .denied }
                }
            }
            #if DEBUG
            // The simulator has no camera. This feeds a decoded string through the same path a real
            // scan takes, for UI checks only; release builds never read it.
            if let simulated = ProcessInfo.processInfo.environment["NTFY_SIMULATED_QR_SCAN"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { deliver(simulated) }
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .scanning:
            QRCaptureView(onCode: deliver)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text(rejected.map(Self.rejectionText) ?? "Point the camera at a topic's QR code.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
        case .needsPermission:
            ProgressView()
        case .denied:
            message(
                icon: "camera",
                text: "NTFY me needs camera access to scan a QR code. You can allow it in Settings, "
                    + "or type the topic and server in instead.",
                action: ("Open Settings", {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }))
        case .unavailable:
            message(icon: "camera", text: "This device has no camera. Type the topic and server in instead.",
                    action: nil)
        }
    }

    private func message(icon: String, text: String, action: (String, () -> Void)?) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.borderedProminent)
                }
                if let rejected {
                    Text(Self.rejectionText(rejected))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    /// Names a rejected web or ntfy link so the user can see what they scanned. Other codes (Wi-Fi
    /// logins, contact cards) can hold secrets, so their text is never put on screen.
    static func rejectionText(_ code: String) -> String {
        let scheme = URLComponents(string: code.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
        guard let scheme, ["http", "https", "ntfy"].contains(scheme) else { return "That code isn't an ntfy topic address." }
        return "That code isn't an ntfy topic address:\n\(code)"
    }

    private func deliver(_ code: String) {
        // The camera reports the same code many times a second; act on each one once.
        guard !accepted, code != rejected else { return }
        if onCode(code) {
            accepted = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            isShowing = false
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            rejected = code
        }
    }
}

/// AVFoundation runs on every iOS 15 device; VisionKit's DataScannerViewController needs iOS 16 and an A12.
private struct QRCaptureView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onCode: onCode)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onCode = onCode
    }

    final class Controller: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        private let session = AVCaptureSession()
        private let preview: AVCaptureVideoPreviewLayer

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            let output = AVCaptureMetadataOutput()
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input), session.canAddOutput(output) else { return }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            for case let code as AVMetadataMachineReadableCodeObject in objects {
                if let value = code.stringValue { onCode(value) }
            }
        }
    }
}
