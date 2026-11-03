//
//  BittensorKeyScreen.swift
//  URnetwork
//
//  The Key screen, the same for both flows (apple/BTEASY.md, and the approved
//  mocks' flows 1 and 2): the words hidden by default, Tap to reveal, Hide and
//  Copy once they show, the not-a-wallet text always, Keep beside the one
//  destructive action, and both behind a check of two of the words. What
//  deleting means, and the check, replace the screen rather than cover it, so
//  the disclaimer shows once.
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
                    // one at a time, so the disclaimer shows once
                    if model.screen.confirming != SdkBittensorLocalKeyConfirmNone {
                        BittensorKeyConfirmation(model: model)
                    } else if model.deleteExplained {
                        BittensorKeyDeleteExplanation(model: model)
                    } else {
                        mainContent
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

        banner

        Text("URnetwork is not a wallet. It created this key so you can receive SN25α. To transfer or use your SN25α, enter this recovery phrase into a Bittensor wallet such as Talisman or Nova, or into btcli.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 8) {
            if !model.screen.address.isEmpty {
                UrLabel(text: "12 words · address \(SnAlpha.shortSs58(model.screen.address))")
            }
            wordsArea
        }

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

        BittensorKeyNotice(systemImage: "exclamationmark.triangle.fill", tint: .urYellow) {
            Text("Anyone with this phrase controls your SN25α. URnetwork will never ask for it, and can't recover it. If you lose this device before saving it, your SN25α can't be reached.")
        }

        Text("Not the seedphrase from sign-up: that one is 24 words and signs you in to URnetwork. This Bittensor recovery phrase is 12 words and holds your SN25α.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)

        if !model.screen.offersRetry {
            VStack(alignment: .leading, spacing: 8) {
                UrLabel(text: "Saved the recovery phrase?")
                if model.screen.offersKeep {
                    UrButton(
                        text: "I've saved it. Keep it on this device.",
                        action: model.confirmKeep,
                        style: .secondary,
                        enabled: !model.screen.busy,
                        accessibilityIdentifier: "earnings.key.keep"
                    )
                }
                BittensorKeyDestructiveButton(
                    text: "I have saved the key, it's OK to delete it now.",
                    filled: false,
                    enabled: !model.screen.busy,
                    accessibilityIdentifier: "earnings.key.delete",
                    action: model.explainDelete
                )
            }
        }

        BittensorFundsDisclaimerText(disclaimer: model.screen.fundsDisclaimer, boxed: true)

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

    /// Signing, a refused consent, or the Save now notice.
    @ViewBuilder
    private var banner: some View {
        if model.screen.busy {
            BittensorKeyNotice(progress: true) {
                Text("Setting up payouts: signing your network's payout consent with this key.")
            }
        } else if model.screen.offersRetry {
            BittensorKeyNotice(systemImage: "exclamationmark.triangle.fill", tint: themeManager.currentTheme.dangerColor) {
                VStack(alignment: .leading, spacing: 8) {
                    if let failure = BittensorKeyText.failure(code: model.screen.failureCode, message: model.screen.failureMessage) {
                        Text(verbatim: failure)
                    }
                    UrButton(
                        text: "Retry",
                        action: model.retry,
                        isProcessing: model.screen.busy,
                        accessibilityIdentifier: "earnings.key.retry"
                    )
                    Text("Payouts aren't set up yet. No earnings went to this key, and leaving discards it.")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }
        } else {
            if model.screen.saveNow {
                BittensorKeyNotice(systemImage: "info.circle.fill", tint: .urLightBlue) {
                    Text("This key isn't saved on this device. Write the 12 words down, then choose below. If you leave this screen, the key is discarded and nothing is paid to it.")
                }
            }
            if let failure = BittensorKeyText.failure(code: model.screen.failureCode, message: model.screen.failureMessage) {
                Text(verbatim: failure)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.dangerColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var wordsArea: some View {
        if model.screen.revealed {
            BittensorKeyProtectedWords(words: model.words, columns: isRegularWidth ? 3 : 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: model.words.joined(separator: " ")))
                .accessibilityIdentifier("earnings.key.words")
                .privacySensitive()
            BittensorKeyHideCountdown(untilMillis: model.screen.revealedUntilMillis)
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
            Text("Other apps may be able to read the clipboard. The copy stays on this device and is cleared after 60 s.")
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
                    Image(systemName: model.screen.needsAuthentication ? BittensorDeviceAuthenticator.systemImage : "eye.slash")
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

/// "Hides again in 0:58", counting down to when the words hide themselves.
struct BittensorKeyHideCountdown: View {

    @EnvironmentObject var themeManager: ThemeManager

    let untilMillis: Int64

    /// "0:58": minutes and seconds left, never below 0:00
    static func remaining(untilMillis: Int64, now: Date) -> String {
        let seconds = max(0, Int((Double(untilMillis) / 1000 - now.timeIntervalSince1970).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        if 0 < untilMillis {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let time = Self.remaining(untilMillis: untilMillis, now: context.date)
                Text("Hides again in \(time)")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .monospacedDigit()
            }
        }
    }
}

/// A notice in a tinted box: an icon or a spinner, then its text.
struct BittensorKeyNotice<Content: View>: View {

    @EnvironmentObject var themeManager: ThemeManager

    var systemImage: String = ""
    var tint: Color = .urLightBlue
    var progress = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if progress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .foregroundColor(tint)
                    .accessibilityHidden(true)
            }
            content()
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .cornerRadius(8)
    }
}

/// What deleting means, before anything happens: no way back, where earnings
/// keep going, what only the phrase can do, and convert ending. On Save now the
/// same step sets up payouts first. Continue asks for two of the words.
struct BittensorKeyDeleteExplanation: View {

    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var model: BittensorKeyModel

    private var address: String {
        SnAlpha.shortSs58(model.screen.address)
    }

    var body: some View {
        Group {
            if model.screen.saveNow {
                Text("Set up payouts and delete the key?")
            } else {
                Text("Delete the key from this device?")
            }
        }
            .font(themeManager.currentTheme.toolbarTitleFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 8) {
            if model.screen.saveNow {
                bullet(Text("Payouts go to this address, \(address), from the next epoch."))
                bullet(Text("URnetwork can't get this key back."))
                bullet(Text("Only the recovery phrase can move your SN25α."))
                bullet(Text("Convert to TAO needs this key, so it won't be available in this app."))
            } else {
                bullet(Text("URnetwork can't get this key back."))
                bullet(Text("Earnings keep going to this address, \(address)."))
                bullet(Text("Only the recovery phrase can move them."))
                bullet(Text("Convert to TAO stops working in this app."))
            }
        }

        if model.screen.warnsTop200 {
            BittensorKeyNotice(systemImage: "crown.fill", tint: .urReferralGold) {
                Text("Deleting this key also gives up claiming a Top 200 spot with one tap. You could still claim from a Bittensor wallet holding this recovery phrase.")
            }
        }

        BittensorKeyWording()

        BittensorFundsDisclaimerText(disclaimer: model.screen.fundsDisclaimer, boxed: true)

        BittensorKeyDestructiveButton(
            text: "Continue",
            accessibilityIdentifier: "earnings.key.deleteContinue",
            action: model.confirmDelete
        )

        Button(action: model.cancelDelete) {
            Text("Cancel")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("earnings.key.deleteCancel")
    }

    private func bullet(_ text: Text) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "•")
                .accessibilityHidden(true)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(themeManager.currentTheme.secondaryBodyFont)
        .foregroundColor(themeManager.currentTheme.textColor)
    }
}

/// Two of the words, which prove the phrase is saved: before the key goes, or
/// before it signs on Save now, or to keep it. Each field says as it's typed
/// whether its word is wrong, and the button acts only with both right.
/// Deleting a stored key asks for device authentication at the button.
struct BittensorKeyConfirmation: View {

    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var model: BittensorKeyModel

    @State private var firstWord = ""
    @State private var secondWord = ""

    private var keeps: Bool {
        model.screen.confirming == SdkBittensorLocalKeyConfirmKeep
    }

    private var check: BittensorKeyWordCheckInfo {
        model.checkWords(first: firstWord, second: secondWord)
    }

    var body: some View {
        let check = check
        Group {
            if keeps {
                Text("Keep the key on this device?")
            } else {
                Text("Enter two of the words")
            }
        }
            .font(themeManager.currentTheme.toolbarTitleFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)

        if keeps {
            Group {
                if model.screen.saveNow {
                    Text("You've saved the recovery phrase. The key is stored on this device for convert and one-tap Top 200, and then payouts are set up.")
                } else {
                    Text("You've saved the recovery phrase, so the backup reminder ends. The key stays on this device for convert and one-tap Top 200.")
                }
            }
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
            line("To confirm, enter these two words from the phrase.")
        } else {
            line("To confirm you've saved the recovery phrase, enter these two words from it.")
        }

        wordField(position: model.screen.firstWordPosition, text: $firstWord, state: check.first, identifier: "earnings.key.word1")
        wordField(position: model.screen.secondWordPosition, text: $secondWord, state: check.second, identifier: "earnings.key.word2")

        if model.screen.wordsRejected {
            Text("Those words don't match. Check your saved recovery phrase.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.dangerColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let failure = BittensorKeyText.failure(code: model.screen.failureCode, message: model.screen.failureMessage) {
            Text(verbatim: failure)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.dangerColor)
                .fixedSize(horizontal: false, vertical: true)
        }

        BittensorFundsDisclaimerText(disclaimer: model.screen.fundsDisclaimer, boxed: true)

        if keeps {
            UrButton(
                text: "Keep it on this device",
                action: submit,
                enabled: check.ready,
                isProcessing: model.screen.busy,
                accessibilityIdentifier: "earnings.key.confirm"
            )
        } else {
            BittensorKeyDestructiveButton(
                text: model.screen.saveNow ? "Set up payouts and delete key" : "Delete key",
                systemImage: model.screen.confirmNeedsAuthentication ? BittensorDeviceAuthenticator.systemImage : nil,
                enabled: check.ready,
                isProcessing: model.screen.busy,
                accessibilityIdentifier: "earnings.key.confirm",
                action: submit
            )
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

    private func submit() {
        let first = firstWord
        let second = secondWord
        Task {
            await model.submitWords(first: first, second: second)
        }
    }

    private func line(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func wordField(position: Int, text: Binding<String>, state: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            UrLabel(text: "Word \(position)")
            BittensorKeyWordField(
                placeholder: String(localized: "Word \(position)"),
                text: text,
                accessibilityIdentifier: identifier
            )
            .frame(maxWidth: .infinity)
            .privacySensitive()
            if state == SdkBittensorLocalKeyWordWrong {
                Text("That isn't word \(position) of this recovery phrase.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.dangerColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier + ".wrong")
            }
        }
    }
}

#if os(iOS)

/// A field for one word of the recovery phrase that the keyboard learns
/// nothing from and suggests nothing in: no autocorrection, spell check,
/// predictions or smart punctuation, and a plain keyboard. SwiftUI's
/// TextField can't turn all of these off.
struct BittensorKeyWordField: UIViewRepresentable {

    let placeholder: String
    @Binding var text: String
    let accessibilityIdentifier: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        )
        field.adjustsFontForContentSizeCategory = true
        Self.quiet(field)
        field.returnKeyType = .done
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text {
            field.text = text
        }
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        field.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// Everything that would learn the word, or offer one, is off.
    static func quiet(_ field: UITextField) {
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .asciiCapable
        if #available(iOS 17.0, *) {
            field.inlinePredictionType = .no
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {

        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func changed(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}

#elseif os(macOS)

/// A field for one word of the recovery phrase that suggests and corrects
/// nothing: its field editor has spelling, completion, substitutions and
/// inline predictions off while it edits.
struct BittensorKeyWordField: NSViewRepresentable {

    let placeholder: String
    @Binding var text: String
    let accessibilityIdentifier: String

    func makeNSView(context: Context) -> BittensorKeyWordTextField {
        let field = BittensorKeyWordTextField()
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: BittensorKeyWordTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {

        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Quiets the window's field editor as soon as it comes to this field, before
/// the first key. The Key screen's sheet has no other text field to share it.
final class BittensorKeyWordTextField: NSTextField {

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let editor = currentEditor() as? NSTextView {
            Self.quiet(editor)
        }
        return became
    }

    /// Everything that would correct the word, or offer one, is off.
    static func quiet(_ editor: NSTextView) {
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        if #available(macOS 14.0, *) {
            editor.inlinePredictionType = .no
        }
    }
}

#endif

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

/// The destructive action: coral, with dark text for contrast (white on coral
/// is 2.8:1, dark 6.8:1), or a coral outline where it sits beside the safe
/// choice. An optional icon says it asks for device authentication.
struct BittensorKeyDestructiveButton: View {

    @EnvironmentObject var themeManager: ThemeManager

    let text: LocalizedStringKey
    var filled = true
    var systemImage: String? = nil
    var enabled = true
    var isProcessing = false
    var accessibilityIdentifier: String = ""
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(themeManager.currentTheme.bodyFont.weight(.semibold))
            .foregroundColor(filled ? Color.urBlack : themeManager.currentTheme.dangerColor)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .background(filled ? themeManager.currentTheme.dangerColor : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(themeManager.currentTheme.dangerColor, lineWidth: filled ? 0 : 1)
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
