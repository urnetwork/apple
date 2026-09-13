//
//  ShareExtendersView.swift
//  URnetwork
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import URnetworkSdk

/**
 * Share extenders (EXTENDER.md K7).
 *
 * The sdk builds the `ur-ext:1:` payload — addresses only, active first, at
 * most 48, never keys or records — and this screen renders it as a QR code at
 * error correction level H with the connector mark centered, plus the payload
 * as copyable text and the system share sheet. "Include extender settings"
 * adds the operator block, off by default, which an importer applies only when
 * it asks to.
 */
struct ShareExtendersView: View {

    @EnvironmentObject var themeManager: ThemeManager

    @ObservedObject var store: ExtenderSettingsStore

    @State private var includeSettings: Bool = false
    @State private var share: ExtenderShare = .empty

    private let codeSize: CGFloat = 240

    var body: some View {

        StatsSheetContainer(title: "Share extenders") {

            ScrollView {

                VStack(alignment: .leading, spacing: 16) {

                    HStack {
                        Spacer(minLength: 0)
                        ExtenderShareCode(text: share.text, size: codeSize)
                        Spacer(minLength: 0)
                    }

                    Text("\(share.count) extenders")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text("Scan this code with another URnetwork app to share these extenders.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .center)

                    UrSwitchToggle(isOn: $includeSettings) {
                        Text("Include extender settings")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }

                    // K7: the payload is also readable and copyable, for a
                    // channel that carries text but not a camera
                    Text(share.text)
                        .font(.system(size: 11).monospaced())
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button("Copy") {
                                copyShareText()
                            }
                        }

                    UrButton(
                        text: "Copy share text",
                        action: copyShareText,
                        style: .outlineSecondary,
                        enabled: !share.isEmpty,
                        leadingSystemImage: "doc.on.doc"
                    )

                    if !share.isEmpty {
                        ShareLink(item: share.text) {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share extenders")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                }
                .padding()
                .tabletReadableColumn()

            }

        }
        .onAppear {
            rebuild()
        }
        .onChange(of: includeSettings) { _ in
            rebuild()
        }
    }

    private func rebuild() {
        share = store.buildShare(includeSettings: includeSettings)
    }

    private func copyShareText() {
        guard !share.isEmpty else {
            return
        }
        #if os(iOS)
        UIPasteboard.general.string = share.text
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(share.text, forType: .string)
        #endif
        // no confirmation snackbar: the localization store carries no "copied"
        // string for this screen, and inventing one here would not translate
    }
}

/**
 * The share payload as a QR code with the connector mark in the middle: the
 * code at error correction level H, and the mark drawn black with a 4pt white
 * outline of its own shape, so the mark reads cleanly against the modules and
 * the lost modules stay inside what level H recovers (K7).
 */
struct ExtenderShareCode: View {

    let text: String
    let size: CGFloat

    // the code is generated once per payload, not on every body evaluation
    @State private var image: CGImage? = nil

    /// the mark's share of the code's width; level H recovers about 30% of the
    /// modules, and a fifth of the width is well inside that
    private var markSize: CGFloat { size * 0.2 }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    // the generated code is one pixel per module: never smooth it
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: size, height: size)
            }

            ZStack {
                // a 4pt outline of the connector shape: the stroke straddles
                // the edge, so half of an 8pt line shows outside and the fill
                // covers the half inside
                ConnectorShape()
                    .stroke(Color.white, lineWidth: extenderShareMarkOutlineWidth * 2)
                ConnectorShape()
                    .fill(Color.black)
            }
            .frame(width: markSize, height: markSize)
        }
        .frame(width: size, height: size)
        .background(Color.white)
        .accessibilityHidden(true)
        .onAppear {
            image = extenderShareQrImage(text)
        }
        .onChange(of: text) { text in
            image = extenderShareQrImage(text)
        }
    }
}

/// the white band around the connector mark, K7
let extenderShareMarkOutlineWidth: CGFloat = 4

/// The QR code of a payload at error correction level H, one pixel per module.
/// Nil for an empty payload or a code the generator refuses.
func extenderShareQrImage(_ text: String) -> CGImage? {
    guard !text.isEmpty, let data = text.data(using: .utf8) else {
        return nil
    }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = data
    // K7: level H, so the centered mark costs modules the code can recover
    filter.correctionLevel = "H"
    guard let output = filter.outputImage else {
        return nil
    }
    return CIContext().createCGImage(output, from: output.extent)
}

/**
 * The URnetwork connector mark as a path, normalized to the unit square of the
 * shape in `ur.symbols.connector.fill` (the same outline the widgets and the
 * onboarding draw). A shape rather than the symbol image so the 4pt outline is
 * a real stroke of the mark's own edge.
 */
struct ConnectorShape: Shape {

    func path(in rect: CGRect) -> Path {
        // the mark is square; center it in whatever it is given
        let side = min(rect.width, rect.height)
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * side, y: originY + y * side)
        }

        var path = Path()
        path.move(to: pt(0.3125, 0.0))
        path.addCurve(to: pt(0.25, 0.0625), control1: pt(0.27798, 0.0), control2: pt(0.25, 0.02798))
        path.addCurve(to: pt(0.1875, 0.125), control1: pt(0.25, 0.09702), control2: pt(0.22202, 0.125))
        path.addCurve(to: pt(0.125, 0.1875), control1: pt(0.15298, 0.125), control2: pt(0.125, 0.15298))
        path.addCurve(to: pt(0.0625, 0.25), control1: pt(0.125, 0.22202), control2: pt(0.09702, 0.25))
        path.addCurve(to: pt(0.0, 0.3125), control1: pt(0.02798, 0.25), control2: pt(0.0, 0.27798))
        path.addLine(to: pt(0.0, 0.6875))
        path.addCurve(to: pt(0.0625, 0.75), control1: pt(0.0, 0.72202), control2: pt(0.02798, 0.75))
        path.addCurve(to: pt(0.125, 0.8125), control1: pt(0.09702, 0.75), control2: pt(0.125, 0.77798))
        path.addCurve(to: pt(0.1875, 0.875), control1: pt(0.125, 0.84702), control2: pt(0.15298, 0.875))
        path.addCurve(to: pt(0.25, 0.9375), control1: pt(0.22202, 0.875), control2: pt(0.25, 0.90298))
        path.addCurve(to: pt(0.3125, 1.0), control1: pt(0.25, 0.97202), control2: pt(0.27798, 1.0))
        path.addLine(to: pt(0.6875, 1.0))
        path.addCurve(to: pt(0.75, 0.9375), control1: pt(0.72202, 1.0), control2: pt(0.75, 0.97202))
        path.addCurve(to: pt(0.8125, 0.875), control1: pt(0.75, 0.90298), control2: pt(0.77798, 0.875))
        path.addCurve(to: pt(0.875, 0.8125), control1: pt(0.84702, 0.875), control2: pt(0.875, 0.84702))
        path.addCurve(to: pt(0.9375, 0.75), control1: pt(0.875, 0.77798), control2: pt(0.90298, 0.75))
        path.addCurve(to: pt(1.0, 0.6875), control1: pt(0.97202, 0.75), control2: pt(1.0, 0.72202))
        path.addLine(to: pt(1.0, 0.3125))
        path.addCurve(to: pt(0.9375, 0.25), control1: pt(1.0, 0.27798), control2: pt(0.97202, 0.25))
        path.addCurve(to: pt(0.875, 0.1875), control1: pt(0.90298, 0.25), control2: pt(0.875, 0.22202))
        path.addCurve(to: pt(0.8125, 0.125), control1: pt(0.875, 0.15298), control2: pt(0.84702, 0.125))
        path.addCurve(to: pt(0.75, 0.0625), control1: pt(0.77798, 0.125), control2: pt(0.75, 0.09702))
        path.addCurve(to: pt(0.6875, 0.0), control1: pt(0.75, 0.02798), control2: pt(0.72202, 0.0))
        path.closeSubpath()
        return path
    }
}
