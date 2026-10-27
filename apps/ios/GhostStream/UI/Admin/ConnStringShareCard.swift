//
//  ConnStringShareCard.swift
//  GhostStream
//
//  QR of a client's ghs:// link + Share + Copy. The link carries the
//  client's private key — the card says so.
//

import CoreImage.CIFilterBuiltins
import PhantomUI
import SwiftUI
import UIKit

struct ConnStringShareCard: View {
    let connString: String

    @Environment(\.gsColors) private var C
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let qr = Self.qrImage(connString) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                    .frame(width: 132, height: 132)
                    .background(Color(hex: 0xFFF1ECDC), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel(L("admin.conn.qr"))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("admin.conn.warning"))
                    .font(.custom(GsFontName.jetBrainsMono, size: 10.5))
                    .foregroundStyle(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                ShareLink(item: connString) {
                    Text(L("admin.conn.share").uppercased())
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                Button {
                    UIPasteboard.general.string = connString
                    copied = true
                } label: {
                    Text(L(copied ? "admin.conn.copied" : "admin.conn.copy").uppercased())
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
            }
            .font(.custom(GsFontName.departureMono, size: 10.5))
            .tracking(1.2)
            .tint(C.bone)
        }
        .padding(18)
        .gsCardBackground(C)
    }

    /// CoreImage QR, scaled up without smoothing.
    static func qrImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    private func L(_ key: String) -> String {
        AppStrings.localized(key)
    }
}
