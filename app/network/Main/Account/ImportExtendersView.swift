//
//  ImportExtendersView.swift
//  URnetwork
//

import SwiftUI
import PhotosUI
import Vision
import URnetworkSdk

#if os(iOS)
import AVFoundation
import VisionKit
#endif

/**
 * Import extenders (EXTENDER.md K7, K8).
 *
 * A payload arrives by camera scan, by a chosen photo, or pasted as text; the
 * sdk decodes it and says what it would do, and nothing is applied until the
 * user acts on that. A payload naming another operator's network is refused
 * unless its settings are taken too, which replaces this space's extender dns
 * name, gossip url and trust anchor — so that case is confirmed first.
 *
 * Platforms (K8): iOS scans with VisionKit and decodes photos with Vision;
 * macOS has no camera entry.
 */
struct ImportExtendersView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var store: ExtenderSettingsStore

    /// the payload text behind the current decision
    @State private var payload: String = ""
    @State private var decision: ExtenderImportDecision? = nil
    @State private var useSettings: Bool = false
    /// what went wrong with the last attempt, nil when nothing did
    @State private var failure: LocalizedStringKey? = nil

    @State private var photoItem: PhotosPickerItem? = nil
    @State private var confirming: Bool = false

    #if os(iOS)
    @State private var scanning: Bool = false
    #endif
    #if os(macOS)
    @State private var choosingFile: Bool = false
    #endif

    var body: some View {

        StatsSheetContainer(title: "Import extenders") {

            ScrollView {

                VStack(alignment: .leading, spacing: 16) {

                    sources

                    if let failure {
                        Text(failure)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(.urCoral)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let decision {
                        decisionSection(decision)
                    }

                }
                .padding()
                .tabletReadableColumn()

            }

        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                await decodePhoto(item)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $scanning) {
            ExtenderCodeScannerView(
                onCode: { text in
                    scanning = false
                    decode(text)
                },
                onCancel: { scanning = false }
            )
        }
        #endif
        #if os(macOS)
        .fileImporter(
            isPresented: $choosingFile,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                decodeImageFile(urls.first)
            case .failure:
                failure = "No QR code was found in the image."
            }
        }
        #endif
        .confirmationDialog(
            settingsConfirmationMessage,
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Use extender settings") {
                runImport()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: sources

    @ViewBuilder
    private var sources: some View {

        #if os(iOS)
        // K8: VisionKit camera scan, iOS only
        UrButton(
            text: "Scan QR code",
            action: startScanning,
            style: .outlineSecondary,
            leadingSystemImage: "qrcode.viewfinder"
        )
        #endif

        #if os(macOS)
        // K8: macOS has no camera entry; an image file covers photos and files
        UrButton(
            text: "Choose photo",
            action: { choosingFile = true },
            style: .outlineSecondary,
            leadingSystemImage: "photo"
        )
        #else
        PhotosPicker(selection: $photoItem, matching: .images) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                Text("Choose photo")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        #endif

        UrButton(
            text: "Paste share text",
            action: pasteShareText,
            style: .outlineSecondary,
            leadingSystemImage: "doc.on.clipboard"
        )
    }

    // MARK: the decision

    @ViewBuilder
    private func decisionSection(_ decision: ExtenderImportDecision) -> some View {

        Divider()
            .background(themeManager.currentTheme.borderBaseColor)

        switch decision {

        case .invalid:
            Text("This code is not an extender share.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(.urCoral)
                .fixedSize(horizontal: false, vertical: true)

        case .foreignWithoutSettings(let networkHost):
            Text("This code is for \(networkHost), not this network. Use extender settings to switch networks.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(.urCoral)
                .fixedSize(horizontal: false, vertical: true)

        case .ready(let count, let hasSettings, let settingsHost, let requiresSettings):

            Text("\(count) extenders")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)

            if hasSettings {
                UrSwitchToggle(isOn: $useSettings) {
                    Text("Use extender settings")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
            }

            if requiresSettings {
                // the payload names another operator: its addresses are taken
                // only together with its settings
                Text("Use the extender settings from this code? Extender lookups will use \(settingsHost).")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            UrButton(
                text: "Import extenders",
                action: confirmOrImport,
                enabled: extenderImportAllowed(decision, useSettings: useSettings)
            )
        }
    }

    /// The message of the settings confirmation: taking a payload's settings
    /// replaces this space's extender lookups (K7).
    private var settingsConfirmationMessage: Text {
        guard case .ready(_, _, let settingsHost, _) = decision else {
            return Text(verbatim: "")
        }
        return Text("Use the extender settings from this code? Extender lookups will use \(settingsHost).")
    }

    // MARK: actions

    private func decode(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        failure = nil
        payload = text
        let decision = store.decodeShare(text)
        self.decision = decision
        // a foreign payload can only be taken with its settings, so start there
        if case .ready(_, let hasSettings, _, let requiresSettings) = decision {
            useSettings = hasSettings && requiresSettings
        } else {
            useSettings = false
        }
    }

    private func confirmOrImport() {
        guard let decision else {
            return
        }
        if extenderImportNeedsConfirmation(decision, useSettings: useSettings) {
            confirming = true
            return
        }
        runImport()
    }

    private func runImport() {
        // the refusal message names the payload's network, so read it before
        // the decision is cleared
        let networkHost = payloadNetworkHost
        switch store.importShare(payload, useSettings: useSettings) {
        case .imported(let count):
            snackbarManager.showSnackbar(
                message: String(localized: "Imported \(count) extenders")
            )
            dismiss()
        case .failed(let error):
            decision = nil
            failure = error == SdkExtenderImportErrorForeignHost
                ? "This code is for \(networkHost), not this network. Use extender settings to switch networks."
                : "This code is not an extender share."
        }
    }

    /// the network host the last decode reported, for a refusal message
    private var payloadNetworkHost: String {
        if case .foreignWithoutSettings(let networkHost) = decision {
            return networkHost
        }
        return store.placeholders.networkHost
    }

    private func pasteShareText() {
        #if canImport(UIKit)
        let text = UIPasteboard.general.string
        #elseif canImport(AppKit)
        let text = NSPasteboard.general.string(forType: .string)
        #else
        let text: String? = nil
        #endif
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            decision = .invalid
            return
        }
        decode(text)
    }

    #if os(iOS)
    private func startScanning() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            scanning = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        scanning = true
                    } else {
                        failure = "Camera access is needed to scan a code."
                    }
                }
            }
        default:
            failure = "Camera access is needed to scan a code."
        }
    }
    #endif

    private func decodePhoto(_ item: PhotosPickerItem) async {
        let data = try? await item.loadTransferable(type: Data.self)
        await MainActor.run {
            photoItem = nil
            guard let data, let text = extenderQrPayload(imageData: data) else {
                decision = nil
                failure = "No QR code was found in the image."
                return
            }
            decode(text)
        }
    }

    #if os(macOS)
    private func decodeImageFile(_ url: URL?) {
        guard let url else {
            failure = "No QR code was found in the image."
            return
        }
        // a file chosen through the importer is reachable only inside the scope
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url),
              let text = extenderQrPayload(imageData: data) else {
            decision = nil
            failure = "No QR code was found in the image."
            return
        }
        decode(text)
    }
    #endif
}

/// The first QR payload in an image, or nil when it carries none (K8: Vision
/// on apple, never a bundled decoder).
func extenderQrPayload(imageData: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    return extenderQrPayload(cgImage: image)
}

func extenderQrPayload(cgImage: CGImage) -> String? {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return nil
    }
    for observation in request.results ?? [] {
        if let payload = observation.payloadStringValue, !payload.isEmpty {
            return payload
        }
    }
    return nil
}

#if os(iOS)
/**
 * The VisionKit live camera scan (K8). Reports the first QR payload it reads
 * and then closes; the caller decides what it is.
 */
struct ExtenderCodeScannerView: View {

    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                ExtenderDataScanner(onCode: onCode)
                    .ignoresSafeArea()
            } else {
                // a device with no scanner (the simulator, older hardware):
                // the other two sources still work
                Color.black.ignoresSafeArea()
                Text("Camera access is needed to scan a code.")
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button(action: onCancel) {
                Text("Cancel")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .foregroundColor(.white)
            }
            .padding()
        }
    }
}

private struct ExtenderDataScanner: UIViewControllerRepresentable {

    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        /// the first code wins; the scanner keeps reporting until it is torn down
        private var reported = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            report(addedItems)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            report([item])
        }

        private func report(_ items: [RecognizedItem]) {
            guard !reported else {
                return
            }
            for item in items {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue,
                   !payload.isEmpty {
                    reported = true
                    onCode(payload)
                    return
                }
            }
        }
    }
}
#endif
