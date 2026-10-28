//
//  RuCertsSheet.swift
//  GhostStream
//
//  «Сертификаты Минцифры»: explains the restricted trust profile
//  (Name Constraints .ru/.рф/.su) and hands it to Safari — iOS installs
//  configuration profiles only from Safari, Mail or AirDrop.
//

import Network
import PhantomUI
import SwiftUI
import UIKit

struct RuCertsSheet: View {
    let onDismiss: () -> Void

    @State private var sent = false
    @Environment(\.gsColors) private var C

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if sent { steps } else { explain }
                }
                .padding(18)
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(L(sent ? "ru.certs.steps.title" : "ru.certs.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onDismiss) {
                        Label(L("general.cancel"), systemImage: "xmark")
                    }
                }
            }
        }
    }

    // MARK: - Explain

    @ViewBuilder
    private var explain: some View {
        hero("ru.certs.hero")
        block(L("ru.certs.what.label")) {
            para(L("ru.certs.what.body1"))
            para(L("ru.certs.what.body2"))
        }
        block(L("ru.certs.zones.label")) {
            para(L("ru.certs.zones.body"))
            // Five chips don't fit one line on a 320 pt phone.
            ViewThatFits {
                HStack(spacing: 6) { goodZones; badZones }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { goodZones }
                    HStack(spacing: 6) { badZones }
                }
            }
            .padding(.top, 2)
        }
        block(L("ru.certs.plus.label"), color: C.signal) {
            bullets(["ru.certs.plus.1", "ru.certs.plus.2", "ru.certs.plus.3"], mark: "+", color: C.signal)
        }
        block(L("ru.certs.risk.label"), color: C.warn) {
            bullets(["ru.certs.risk.1", "ru.certs.risk.2"], mark: "!", color: C.warn)
        }
        block(L("ru.certs.need.label")) {
            para(L("ru.certs.need.body"))
        }
        block(L("ru.certs.remove.label")) {
            para(L("ru.certs.remove.body"), color: C.textDim)
        }
        pill(L("ru.certs.install"), primary: true) {
            ProfileServer.shared.serve(resource: "ru-only.mobileconfig")
            sent = true
        }
        pill(L("ru.certs.later"), primary: false, action: onDismiss)
    }

    @ViewBuilder private var goodZones: some View {
        ForEach([".RU", ".РФ", ".SU"], id: \.self) { zone($0, on: true) }
    }

    @ViewBuilder private var badZones: some View {
        zone(".COM", on: false)
        zone(L("ru.certs.zone.rest").uppercased(), on: false)
    }

    // MARK: - Steps

    @ViewBuilder
    private var steps: some View {
        hero("ru.certs.steps.hero")
        HStack(spacing: 10) {
            Text("✓").foregroundColor(C.signal)
            Text(L("ru.certs.steps.ok")).foregroundColor(C.textDim)
        }
        .font(.custom(GsFontName.jetBrainsMono, size: 11))
        block(nil) {
            ForEach(Array(["ru.certs.step.1", "ru.certs.step.2"].enumerated()), id: \.offset) { idx, key in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(idx + 1)")
                        .font(.custom(GsFontName.departureMono, size: 10))
                        .foregroundColor(C.signal)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(C.signal, lineWidth: 1))
                    para(L(key))
                }
                .padding(.bottom, 6)
            }
            para(L("ru.certs.steps.note"), color: C.textDim)
        }
        pill(L("ru.certs.open.settings"), primary: true) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        pill(L("ru.certs.done"), primary: false, action: onDismiss)
    }

    // MARK: - Pieces

    /// «Чтобы сайты *российских банков* открывались…»: key.1 + italic key.2 + key.3.
    private func hero(_ key: String) -> some View {
        (Text(L(key + ".1"))
            + Text(L(key + ".2")).font(.custom(GsFontName.instrumentSerifItalic, size: 25)).foregroundColor(C.signal)
            + Text(L(key + ".3")))
            .font(.custom(GsFontName.instrumentSerif, size: 25))
            .foregroundColor(C.bone)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func block<Content: View>(
        _ label: String?,
        color: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label.uppercased())
                    .gsFont(.labelMono)
                    .foregroundStyle(color ?? C.textDim)
                    .padding(.bottom, 2)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(C.bgElev2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func para(_ text: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.custom(GsFontName.jetBrainsMono, size: 11.5))
            .foregroundColor(color ?? C.bone)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullets(_ keys: [String], mark: String, color: Color) -> some View {
        ForEach(keys, id: \.self) { key in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mark)
                    .font(.custom(GsFontName.jetBrainsMono, size: 11.5))
                    .foregroundColor(color)
                    .frame(width: 8)
                para(L(key))
            }
        }
    }

    private func zone(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.custom(GsFontName.departureMono, size: 10))
            .tracking(1)
            .strikethrough(!on)
            .foregroundColor(on ? C.signal : C.textFaint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(on ? C.signal : C.hair, lineWidth: 1))
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.custom(GsFontName.departureMono, size: 11))
                .tracking(2)
                .foregroundColor(primary ? C.bg : C.textDim)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(primary ? C.signal : C.bone.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Loopback HTTP server that hands one file to Safari: Safari is what lets
/// iOS install a configuration profile. Lives ~60 s or until the file is served.
@MainActor
final class ProfileServer {
    static let shared = ProfileServer()

    private var listener: NWListener?
    private var timeout: DispatchWorkItem?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    func serve(resource name: String) {
        stop()
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
              let file = try? Data(contentsOf: url) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: params) else { return }
        self.listener = listener

        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-apple-aspen-config\r\n"
            + "Content-Length: \(file.count)\r\nConnection: close\r\n\r\n"
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { request, _, _, _ in
                // Any GET gets the file; stop once Safari fetched the real path
                // (a favicon probe must not end the server).
                let served = request.map { String(decoding: $0, as: UTF8.self).contains(name) } ?? false
                conn.send(content: Data(head.utf8) + file, completion: .contentProcessed { _ in
                    conn.cancel()
                    if served { MainActor.assumeIsolated { self.stop() } }
                })
            }
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port,
                  let link = URL(string: "http://127.0.0.1:\(port.rawValue)/\(name)") else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(link) }
        }
        listener.start(queue: .main)

        // Safari takes the foreground: keep the listener alive meanwhile.
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stop() } }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        timeout?.cancel()
        timeout = nil
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}

private func L(_ key: String) -> String {
    AppStrings.localized(key)
}
