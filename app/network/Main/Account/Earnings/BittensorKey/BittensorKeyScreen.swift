//
//  BittensorKeyScreen.swift
//  URnetwork
//
//  The Key screen, the same for both flows (apple/BTEASY.md): the words hidden
//  by default, Tap to reveal, Hide and Copy once they show, the not-a-wallet
//  text always, and one destructive action behind a check of two of the words.
//  The SDK's flow decides all of that; this draws it and adds the privacy
//  controls only this platform has. "No screenshots" is best effort on Apple's
//  platforms, so nothing here promises it.
//
//  The words are in the view tree only while they show, so VoiceOver can't read
//  them while hidden. They are plain Text: no selection, no text field. No
//  NSUserActivity comes near this screen, so no Handoff.
//

import SwiftUI
import URnetworkSdk
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct BittensorKeyScreen: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.isRegularWidth) private var isRegularWidth
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #elseif os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    @ObservedObject var model: BittensorKeyModel
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.screen.confirming == SdkBittensorLocalKeyConfirmNone {
                        mainContent
                    } else {
                        BittensorKeyConfirmation(model: model)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .tabletReadableColumn()
            }
            #if os(iOS)
            // the app switcher's snapshot, and anything else over an inactive scene
            if scenePhase != .active {
                appSwitcherCover
            }
            #endif
        }
        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
        #if os(iOS)
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                model.leftForeground()
            }
        }
        .onAppear {
            model.captureChanged(active: UIScreen.main.isCaptured)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            model.captureChanged(active: UIScreen.main.isCaptured)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            model.screenshotTaken()
        }
        #elseif os(macOS)
        .background(BittensorKeyWindowPrivacy())
        .onChange(of: controlActiveState) { state in
            if state != .key {
                model.leftForeground()
            }
        }
        #endif
    }

    @ViewBuilder
    private var mainContent: some View {
        HStack {
            Text("Bittensor recovery phrase")
                .font(themeManager.currentTheme.toolbarTitleFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            Spacer()
        }
        Text("This is not your account seed phrase from sign-up. It only controls this Bittensor key.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)
        if !model.screen.address.isEmpty {
            Text(verbatim: SnAlpha.shortSs58(model.screen.address))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.textColor)
        }

        wordsArea

        if model.screen.hiddenByCapture {
            Text("The words stay hidden while your screen is being recorded or mirrored.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(.urYellow)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.screenshotWarning {
            Text("If that screenshot shows your recovery phrase, delete it. Anyone with this phrase controls your SN25α.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(.urYellow)
                .fixedSize(horizontal: false, vertical: true)
        }

        BittensorKeyWording()

        if let failure = BittensorKeyText.failure(code: model.screen.failureCode, message: model.screen.failureMessage) {
            Text(verbatim: failure)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.dangerColor)
                .fixedSize(horizontal: false, vertical: true)
        }

        if model.screen.offersRetry {
            Text("Payouts aren't set up yet. No earnings went to this key, and leaving discards it.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
            UrButton(
                text: "Retry",
                action: model.retry,
                isProcessing: model.screen.busy,
                accessibilityIdentifier: "earnings.key.retry"
            )
        } else {
            BittensorKeyDestructiveButton(
                text: "I have saved the key, it's OK to delete it now.",
                isProcessing: model.screen.busy,
                accessibilityIdentifier: "earnings.key.delete"
            ) {
                Task {
                    await model.confirmDelete()
                }
            }
            if model.screen.offersKeep {
                BittensorKeyCardLink(
                    text: "I've saved it. Keep it on this device.",
                    action: {
                        Task {
                            await model.confirmKeep()
                        }
                    },
                    accessibilityIdentifier: "earnings.key.keep"
                )
            }
        }

        Button(action: dismiss) {
            Group {
                if model.screen.saveNow {
                    Text("Cancel")
                } else {
                    Text("Close")
                }
            }
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(model.screen.busy)
        .accessibilityIdentifier("earnings.key.close")
    }

    @ViewBuilder
    private var wordsArea: some View {
        if model.screen.revealed {
            BittensorKeyProtectedWords(words: model.words, columns: isRegularWidth ? 3 : 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: model.words.joined(separator: " ")))
                .accessibilityIdentifier("earnings.key.words")
                .privacySensitive()
            HStack(spacing: 8) {
                UrButton(
                    text: "Hide",
                    action: model.hide,
                    style: .outlineSecondary,
                    leadingSystemImage: "eye.slash",
                    accessibilityIdentifier: "earnings.key.hide"
                )
                UrButton(
                    text: model.copied ? "Copied" : "Copy",
                    action: model.copy,
                    style: .outlineSecondary,
                    leadingSystemImage: model.copied ? "checkmark" : "doc.on.doc",
                    accessibilityIdentifier: "earnings.key.copy"
                )
            }
            Text("Other apps may be able to read the clipboard. It's cleared after 60 seconds.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button(action: {
                Task {
                    await model.tapToReveal()
                }
            }) {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 22))
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .accessibilityHidden(true)
                    Text("Tap to reveal")
                        .font(themeManager.currentTheme.bodyFont.weight(.semibold))
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(themeManager.currentTheme.textMutedColor.opacity(0.3), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.screen.hiddenByCapture)
            .accessibilityIdentifier("earnings.key.reveal")
        }
    }

    #if os(iOS)
    private var appSwitcherCover: some View {
        ZStack {
            themeManager.currentTheme.backgroundColor
            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
    #endif
}

/// The confirmation before the key goes, or before it signs on Save now: what
/// deleting means, then two of the words, which is what proves the phrase is
/// saved. For a stored key that stays, the same proof ends the reminders.
struct BittensorKeyConfirmation: View {

    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var model: BittensorKeyModel

    @State private var firstWord = ""
    @State private var secondWord = ""

    private var keeps: Bool {
        model.screen.confirming == SdkBittensorLocalKeyConfirmKeep
    }

    private var canSubmit: Bool {
        !firstWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secondWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if keeps {
                Text("Keep this key on this device?")
            } else {
                Text("Delete this key from this app?")
            }
        }
            .font(themeManager.currentTheme.toolbarTitleFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)

        if !keeps {
            BittensorKeyWording()
            line("URnetwork can't get this key back. Earnings keep going to this address, and only the recovery phrase can move them.")
            if !model.screen.address.isEmpty {
                Text(verbatim: SnAlpha.shortSs58(model.screen.address))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
            line("This app also can't convert your SN25α to TAO after this. A Bittensor wallet or btcli can, with this recovery phrase.")
            if model.screen.warnsTop200 {
                line("Deleting this key also gives up claiming a Top 200 spot with one tap. You could still claim from a Bittensor wallet holding this recovery phrase.")
            }
        }

        line("To show you saved it, enter these two words from your recovery phrase.")

        wordField(position: model.screen.firstWordPosition, text: $firstWord, identifier: "earnings.key.word1")
        wordField(position: model.screen.secondWordPosition, text: $secondWord, identifier: "earnings.key.word2")

        if model.screen.wordsRejected {
            Text("Those words don't match. Check your saved recovery phrase.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.dangerColor)
                .fixedSize(horizontal: false, vertical: true)
        }

        BittensorKeyDestructiveButton(
            text: confirmText,
            enabled: canSubmit,
            isProcessing: model.screen.busy,
            accessibilityIdentifier: "earnings.key.confirm"
        ) {
            model.submitWords(first: firstWord, second: secondWord)
        }

        Button(action: model.cancelConfirmation) {
            Text("Cancel")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(model.screen.busy)
        .accessibilityIdentifier("earnings.key.confirmCancel")
    }

    private var confirmText: LocalizedStringKey {
        if keeps {
            return "Keep key"
        }
        return model.screen.saveNow ? "Set up payouts" : "Delete key"
    }

    private func line(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func wordField(position: Int, text: Binding<String>, identifier: String) -> some View {
        TextField("", text: text, prompt: Text("Word \(position)"))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .privacySensitive()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .accessibilityLabel(Text("Word \(position)"))
            .accessibilityIdentifier(identifier)
    }
}

/// The not-a-wallet text, the plan's words, always in view on the Key screen and
/// in its delete confirmation.
struct BittensorKeyWording: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        Text("URnetwork is not a wallet. It created this key so you can receive SN25α. To transfer or use your SN25α, enter this recovery phrase into a Bittensor wallet such as Talisman or Nova, or into btcli.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)
        Text("Anyone with this phrase controls your SN25α. URnetwork will never ask for it, and can't recover it. If you lose this device before saving it, your SN25α can't be reached.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct BittensorKeyDestructiveButton: View {

    @EnvironmentObject var themeManager: ThemeManager

    let text: LocalizedStringKey
    var enabled = true
    var isProcessing = false
    var accessibilityIdentifier: String = ""
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 8) {
                Text(text)
                    .font(themeManager.currentTheme.bodyFont.weight(.semibold))
                    .foregroundColor(themeManager.currentTheme.dangerColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(themeManager.currentTheme.dangerColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled || isProcessing)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// The twelve words, numbered. Text only, so nothing selects them.
struct BittensorKeyWordGrid: View {

    let words: [String]
    let columns: Int
    let textColor: Color
    let mutedColor: Color
    let background: Color

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 4) {
                    Text(verbatim: "\(index + 1).")
                        .foregroundColor(mutedColor)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 24, alignment: .trailing)
                    Text(verbatim: word)
                        .foregroundColor(textColor)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(background)
                .cornerRadius(6)
            }
        }
        .padding(12)
    }
}

/// The words, as protected as this platform can make them.
struct BittensorKeyProtectedWords: View {

    @EnvironmentObject var themeManager: ThemeManager

    let words: [String]
    let columns: Int

    private var grid: BittensorKeyWordGrid {
        BittensorKeyWordGrid(
            words: words,
            columns: columns,
            textColor: themeManager.currentTheme.textColor,
            mutedColor: themeManager.currentTheme.textMutedColor,
            background: themeManager.currentTheme.tintedBackgroundBase
        )
    }

    var body: some View {
        Group {
            #if os(iOS)
            BittensorKeyCaptureProtected(content: grid)
            #else
            grid
            #endif
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(themeManager.currentTheme.textMutedColor.opacity(0.3), lineWidth: 1)
        )
    }
}

#if os(iOS)

/// Draws its content in a secure text field's layer, which blanks it in
/// screenshots and recordings. iOS has no official API for this: it is widely
/// used and unsupported, so each new iOS needs the check in the report's list.
/// `isProtected` says whether this iOS still has the layer; if it doesn't, the
/// content still shows, and UIScreen.isCaptured still hides it while recording.
struct BittensorKeyCaptureProtected: UIViewRepresentable {

    let content: BittensorKeyWordGrid

    func makeUIView(context: Context) -> BittensorKeyCaptureProtectedView {
        BittensorKeyCaptureProtectedView(content: content)
    }

    func updateUIView(_ uiView: BittensorKeyCaptureProtectedView, context: Context) {
        uiView.update(content: content)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BittensorKeyCaptureProtectedView, context: Context) -> CGSize? {
        uiView.fittingSize(width: proposal.width ?? 320)
    }
}

final class BittensorKeyCaptureProtectedView: UIView {

    private let field = UITextField()
    private let host: UIHostingController<BittensorKeyWordGrid>
    /// the secure layer was found
    private(set) var isProtected = false

    init(content: BittensorKeyWordGrid) {
        host = UIHostingController(rootView: content)
        super.init(frame: .zero)
        host.view.backgroundColor = .clear
        // never first responder: nothing here takes text or a selection
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.backgroundColor = .clear
        field.accessibilityElementsHidden = true
        addSubview(field)
        field.layoutIfNeeded()
        if let canvas = Self.secureCanvas(of: field) {
            canvas.addSubview(host.view)
            isProtected = true
        } else {
            addSubview(host.view)
        }
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The private view the secure text is drawn into.
    private static func secureCanvas(of field: UITextField) -> UIView? {
        field.subviews.first { String(describing: type(of: $0)).contains("CanvasView") } ?? field.subviews.first
    }

    func update(content: BittensorKeyWordGrid) {
        host.rootView = content
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func fittingSize(width: CGFloat) -> CGSize {
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.frame = bounds
        field.layoutIfNeeded()
        host.view.frame = CGRect(origin: .zero, size: bounds.size)
    }
}

#elseif os(macOS)

/// Keeps the sheet's window out of screen sharing and capture for as long as
/// the Key screen is in it. Newer capture APIs are reported not to fully honor
/// this: on the report's list of checks.
struct BittensorKeyWindowPrivacy: NSViewRepresentable {

    func makeNSView(context: Context) -> BittensorKeyWindowPrivacyView {
        BittensorKeyWindowPrivacyView()
    }

    func updateNSView(_ nsView: BittensorKeyWindowPrivacyView, context: Context) {}
}

final class BittensorKeyWindowPrivacyView: NSView {

    private weak var protectedWindow: NSWindow?
    private var previousSharingType: NSWindow.SharingType = .readOnly

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        protectedWindow?.sharingType = previousSharingType
        protectedWindow = window
        if let window {
            previousSharingType = window.sharingType
            window.sharingType = .none
        }
    }
}

#endif

#Preview {
    let flow = BittensorKeyPreviewFlow()
    flow.screen = BittensorKeyScreenInfo(open: true, needsAuthentication: true, offersKeep: true)
    return BittensorKeyScreen(model: BittensorKeyModel(flow: flow), dismiss: {})
        .environmentObject(ThemeManager.shared)
}
