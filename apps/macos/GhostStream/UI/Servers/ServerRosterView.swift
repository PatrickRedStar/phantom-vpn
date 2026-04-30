//
//  ServerRosterView.swift
//  GhostStream (macOS)
//
//  ROSTER tab — pixel-matched to section 05 of the design HTML.
//
//   1. detail-head: lblmono "profiles · N" faint + 38pt hero "roster."
//      with em italic signal serif accent + "● probing rtt · 30s" right.
//   2. toolbar: "+ new profile · ⌘N" (signal border) + "paste ghs://"
//      (hairBold border bone) + count text right.
//   3. SwiftUI Table rows with columns
//        ★ | name (+ ● active) | endpoint (+ sni small)
//          | region badge | rtt (colour by range) | last used | ⋯
//      Active row gets signal.opacity(0.06) bg + 2pt left border.
//

import AppKit
import Foundation
import Network
import PhantomKit
import PhantomUI
import SwiftUI

public struct ServerRosterView: View {

    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles

    @State private var rttCache: [String: UInt32] = [:]
    @State private var showAddSheet = false
    @State private var rosterStatus: String?
    @State private var probeStatus: String = "RTT PROBE UNAVAILABLE"
    @State private var sortOrder: [KeyPathComparator<RosterRow>] = [
        .init(\.name, order: .forward)
    ]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailHead
            toolbar
            if profiles.profiles.isEmpty {
                emptyState
            } else {
                tableView
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(C.bg)
        .sheet(isPresented: $showAddSheet) {
            ProfileEditorSheet()
        }
        .task {
            await probeLoop()
        }
    }

    // MARK: - 1. detail-head

    @ViewBuilder
    private var detailHead: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PROFILES · \(profiles.profiles.count)")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.20 * 11)
                    .foregroundStyle(C.textFaint)
                HStack(spacing: 0) {
                    Text("roster")
                        .font(.custom("InstrumentSerif-Italic", size: 38))
                        .foregroundStyle(C.signal)
                    Text(".")
                        .font(.custom("SpaceGrotesk-Bold", size: 38))
                        .foregroundStyle(C.textDim)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                PulseDot(color: C.textDim, size: 8, pulse: false)
                Text(probeStatus)
                    .font(.custom("DepartureMono-Regular", size: 10.5))
                    .tracking(0.16 * 10.5)
                    .foregroundStyle(C.textDim)
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            DashedHairline()
        }
    }

    // MARK: - 2. toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { showAddSheet = true } label: {
                HStack(spacing: 8) {
                    Text("+ NEW PROFILE")
                        .font(.custom("DepartureMono-Regular", size: 11))
                        .tracking(0.18 * 11)
                    Text("· ⌘N")
                        .font(.custom("DepartureMono-Regular", size: 10))
                        .foregroundStyle(C.signal.opacity(0.6))
                }
                .foregroundStyle(C.signal)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(Rectangle().stroke(C.signal, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)

            Button { pasteFromClipboard() } label: {
                Text("PASTE GHS://")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.18 * 11)
                    .foregroundStyle(C.bone)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(rosterStatus ?? "\(profiles.profiles.count) PROFILES · \(activeCount) ACTIVE · \(probeStatus)")
                .font(.custom("DepartureMono-Regular", size: 10.5))
                .tracking(0.14 * 10.5)
                .foregroundStyle(rosterStatus == nil ? C.textFaint : C.warn)
        }
    }

    private var activeCount: Int {
        profiles.activeId == nil ? 0 : 1
    }

    // MARK: - 3. table

    @ViewBuilder
    private var tableView: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("") { row in
                rowActionArea(row) {
                    Image(systemName: row.isFav ? "star.fill" : "star")
                        .foregroundStyle(row.isFav ? C.warn : C.textFaint)
                        .font(.system(size: 13))
                }
            }
            .width(30)

            TableColumn("name", value: \.name) { row in
                rowActionArea(row) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.custom("SpaceGrotesk-Bold", size: 14))
                            .foregroundStyle(C.bone)
                        if row.active {
                            Text("● ACTIVE")
                                .font(.custom("DepartureMono-Regular", size: 9.5))
                                .tracking(0.14 * 9.5)
                                .foregroundStyle(C.signal)
                        }
                    }
                    .padding(.leading, row.active ? 6 : 0)
                    .overlay(alignment: .leading) {
                        if row.active {
                            Rectangle().fill(C.signal).frame(width: 2)
                        }
                    }
                }
            }
            .width(min: 140)

            TableColumn("endpoint", value: \.endpoint) { row in
                rowActionArea(row) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.endpoint)
                            .font(.custom("JetBrainsMono-Regular", size: 11.5))
                            .foregroundStyle(C.textDim)
                        if !row.sni.isEmpty {
                            Text("sni: \(row.sni)")
                                .font(.custom("JetBrainsMono-Regular", size: 10))
                                .foregroundStyle(C.textFaint)
                        }
                    }
                }
            }

            TableColumn("region") { row in
                rowActionArea(row) {
                    regionBadge(row.region)
                }
            }
            .width(140)

            TableColumn("rtt", value: \.rttSort) { row in
                rowActionArea(row) {
                    Text(row.rttLabel)
                        .font(.custom("DepartureMono-Regular", size: 11))
                        .tracking(0.04 * 11)
                        .foregroundStyle(rttColor(row.rttMs))
                }
            }
            .width(80)

            TableColumn("last used", value: \.status) { row in
                rowActionArea(row) {
                    Text(row.status.lowercased())
                        .font(.custom("JetBrainsMono-Regular", size: 11))
                        .foregroundStyle(C.textDim)
                }
            }
            .width(120)

            TableColumn("") { row in
                rowActionArea(row) {
                    Text("⋯")
                        .foregroundStyle(C.textFaint)
                        .font(.system(size: 14))
                }
            }
            .width(30)
        }
        .scrollContentBackground(.hidden)
        .background(C.bgElev)
        .overlay(Rectangle().stroke(C.hair, lineWidth: 1))
    }

    private func regionBadge(_ region: String) -> some View {
        let color: Color
        let label: String
        switch region.lowercased() {
        case "ru":
            color = C.warn
            label = "ru · sni-passthrough"
        case "nl":
            color = C.signal
            label = "nl · vdsina"
        default:
            color = C.bone
            label = region.isEmpty ? "— internal" : region
        }
        return Text(label)
            .font(.custom("DepartureMono-Regular", size: 9.5))
            .tracking(0.14 * 9.5)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(
                Rectangle().stroke(color.opacity(0.35), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(C.textFaint)
            Text(String(localized: "roster.empty"))
                .font(.custom("JetBrainsMono-Regular", size: 12))
                .foregroundStyle(C.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(C.bgElev2)
        .overlay(Rectangle().stroke(C.hair, lineWidth: 1))
    }

    // MARK: - Rows

    private var rows: [RosterRow] {
        let unsorted = profiles.profiles.map { profile in
            RosterRow(
                id: profile.id,
                name: profile.name,
                endpoint: profile.serverAddr,
                sni: profile.serverName,
                region: detectRegion(profile),
                rttMs: rttCache[profile.id],
                isFav: profiles.activeId == profile.id,
                active: profiles.activeId == profile.id,
                status: profiles.activeId == profile.id ? "just now" : "—",
                connString: profile.connString
            )
        }
        return unsorted.sorted(using: sortOrder)
    }

    private func detectRegion(_ p: VpnProfile) -> String {
        let host = p.serverAddr.lowercased()
        if host.contains("vdsina") { return "nl" }
        if host.contains("relay") || host.contains("193.187") { return "ru" }
        return ""
    }

    private func rttColor(_ rtt: UInt32?) -> Color {
        guard let rtt else { return C.textFaint }
        switch rtt {
        case 0..<20:    return C.signal
        case 20..<100:  return C.bone
        case 100..<200: return C.warn
        default:        return C.danger
        }
    }

    private func probeLoop() async {
        await probeProfilesOnce()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { break }
            await probeProfilesOnce()
        }
    }

    @MainActor
    private func probeProfilesOnce() async {
        let snapshot = profiles.profiles
        guard !snapshot.isEmpty else {
            rttCache = [:]
            probeStatus = "RTT PROBE · EMPTY"
            return
        }

        probeStatus = "PROBING RTT · 30S"
        var nextCache = rttCache
        await withTaskGroup(of: (String, UInt32?).self) { group in
            for profile in snapshot {
                group.addTask {
                    (profile.id, await measureRTT(to: profile.serverAddr))
                }
            }

            for await (id, rtt) in group {
                if let rtt {
                    nextCache[id] = rtt
                } else {
                    nextCache.removeValue(forKey: id)
                }
            }
        }
        rttCache = nextCache
        let measured = snapshot.filter { nextCache[$0.id] != nil }.count
        probeStatus = "RTT \(measured)/\(snapshot.count) · 30S"
    }

    private func measureRTT(to serverAddr: String) async -> UInt32? {
        guard let endpoint = endpoint(from: serverAddr) else { return nil }

        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: endpoint.port, using: .tcp)
        let startedAt = Date()

        return await withCheckedContinuation { continuation in
            let gate = RTTProbeCompletionGate(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = UInt32(max(1, min(9_999, Date().timeIntervalSince(startedAt) * 1_000)))
                    gate.resume(ms)
                case .failed, .waiting:
                    gate.resume(nil)
                case .cancelled, .setup, .preparing:
                    break
                @unknown default:
                    gate.resume(nil)
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                gate.resume(nil)
            }
        }
    }

    private func endpoint(from serverAddr: String) -> (host: String, port: NWEndpoint.Port)? {
        let trimmed = serverAddr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.contains("://") ? trimmed : "tcp://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              let host = components.host,
              !host.isEmpty
        else { return nil }

        let portValue = components.port ?? 443
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: portValue)) else {
            return nil
        }
        return (host, port)
    }

    private func pasteFromClipboard() {
        let str = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let str, !str.isEmpty else {
            rosterStatus = "Clipboard is empty"
            return
        }

        guard str.hasPrefix("ghs://") else {
            rosterStatus = "Clipboard does not contain a ghs:// profile"
            return
        }

        do {
            let profile = try profiles.importFromConnString(str)
            rosterStatus = "Imported \(profile.name)"
        } catch {
            rosterStatus = "Failed to import ghs:// profile"
        }
    }

    @ViewBuilder
    private func rowActionArea<Content: View>(
        _ row: RosterRow,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                profiles.setActive(id: row.id)
                rosterStatus = "Active profile: \(row.name)"
            }
            .contextMenu {
                Button("Set Active") {
                    profiles.setActive(id: row.id)
                    rosterStatus = "Active profile: \(row.name)"
                }
                Button("Edit") {
                    profiles.setActive(id: row.id)
                    showAddSheet = true
                }
                Button("Copy endpoint") {
                    copy(row.endpoint)
                    rosterStatus = "Endpoint copied"
                }
                if let connString = row.connString, !connString.isEmpty {
                    Button("Copy ghs://") {
                        copy(connString)
                        rosterStatus = "ghs:// copied"
                    }
                }
                Button("Delete", role: .destructive) {
                    profiles.remove(id: row.id)
                    rosterStatus = "Deleted \(row.name)"
                }
            }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// MARK: - Row model

private struct RosterRow: Identifiable {
    let id: String
    let name: String
    let endpoint: String
    let sni: String
    let region: String
    let rttMs: UInt32?
    let isFav: Bool
    let active: Bool
    let status: String
    let connString: String?
    var rttLabel: String { rttMs.map { "\($0) ms" } ?? "n/a" }
    var rttSort: UInt32 { rttMs ?? UInt32.max }
}

private final class RTTProbeCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<UInt32?, Never>

    init(connection: NWConnection, continuation: CheckedContinuation<UInt32?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func resume(_ value: UInt32?) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: value)
    }
}
