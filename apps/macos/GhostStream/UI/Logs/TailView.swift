//
//  TailView.swift
//  GhostStream (macOS)
//
//  TAIL tab — pixel-matched to section 03 of the design HTML.
//
//  Layout:
//   1. detail-head: lblmono "live tail" faint + 38pt hero "tail." with
//      em italic signal serif accent + "● 247 lines · streaming" right.
//   2. toolbar: tool-pills [all|info|warn|error|debug] with active state
//      (signal text + signal.opacity(0.06) bg + signal-dim border) and
//      filter input on the right with ⌘F + ⌘L kbd hints.
//   3. table: 86pt ts column / 60pt level column / msg fills the rest.
//      Row colours per level (ok=signal, info=textDim, warn=warn,
//      err=danger, dbg=debug).
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI
import UniformTypeIdentifiers

public struct TailView: View {

    @Environment(\.gsColors) private var C
    @Environment(PreferencesStore.self) private var prefs
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(TunnelLogStore.self) private var logStore

    @State private var activeFilter: LevelFilter = .all
    @State private var searchText: String = ""
    @State private var regexSearch: Bool = false
    @State private var followTail: Bool = true
    @State private var selectedCategories: Set<String> = []
    @State private var actionStatus: TailStatus?
    @State private var actionStatusTtlTask: Task<Void, Never>?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var regexDebounceTask: Task<Void, Never>?
    // UI-C1: cached filter result. The previous `var filteredLogs`
    // computed property re-ran `TailViewFilter.filter` 3+ times per
    // body invocation (counts + ForEach + status strip). On a 50k row
    // buffer that's tens of ms × 3 every time `logStore.logs` changed.
    // We now recompute exactly once whenever the inputs change.
    //
    // TODO(UI-R2-N01): when both the embedded TailView (sidebar
    // channel) and the detached Logs window are open, each instance
    // owns its own `@State cachedFilteredLogs` — doubling memory
    // (~25 MB worst case on a 50k buffer). The proper fix is a shared
    // observable view-model keyed on filter inputs, similar to
    // `TrafficSeriesStore`. Skipped in Round 3 because filter inputs
    // (activeFilter / search / categories) are also per-view, so a
    // naïve singleton would need keyed caches. Out of scope for this
    // sweep.
    @State private var cachedFilteredLogs: [LogFrame] = []
    /// UI-R4-R05: confirmation gate before flushing the in-memory log
    /// buffer. The previous ⌘⌫ shortcut collided with the standard
    /// TextField "delete to start of line" chord, so the buffer could
    /// be wiped while the user was deleting a word in the filter input.
    /// We now require an explicit Clear tap through a confirmation
    /// dialog *and* moved the chord to ⇧⌘⌫ so it can't fire from
    /// inside a TextField.
    @State private var showClearConfirm: Bool = false
    @FocusState private var searchFieldFocused: Bool

    /// Static formatter — UI-C2. Allocating a fresh `DateFormatter`
    /// for every row (potentially thousands per scroll) is heavy:
    /// each instance pulls locale/calendar data. The format itself
    /// is locale-independent so a singleton is safe.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailHead
            toolbar
            categoryStrip
            tailStatusStrip
            tailTable
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(C.bg)
        // UI-C1: recompute the filter cache exactly when one of its
        // inputs flips. The body never recomputes — readers just
        // observe `cachedFilteredLogs`.
        .onAppear { recomputeFilteredLogs() }
        .onChange(of: logStore.logs.count) { _, _ in recomputeFilteredLogs() }
        .onChange(of: activeFilter) { _, _ in recomputeFilteredLogs() }
        .onChange(of: selectedCategories) { _, _ in recomputeFilteredLogs() }
        // UI-R2-N10: debounce regexSearch toggle too — recomputing on
        // a 50k row buffer is ~50ms and the toggle previously ran on
        // the main thread without yielding.
        .onChange(of: regexSearch) { _, _ in
            regexDebounceTask?.cancel()
            let task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                recomputeFilteredLogs()
            }
            regexDebounceTask = task
        }
        .onChange(of: searchText) { _, _ in
            // UI-R4-R09: cancel the previous debounce *first* — even
            // when we early-return for an invalid regex. Round 2 left
            // the task armed, so the next keystroke after typing an
            // invalid pattern would fire two recomputes (the stale
            // debounce from the prior valid input + the fresh one).
            // Cancelling unconditionally guarantees exactly one
            // recompute per pause.
            searchDebounceTask?.cancel()

            // UI-R2-R05: when regex mode is on and the pattern is
            // currently invalid, zero out the cache *synchronously*
            // so the table doesn't keep showing stale matches against
            // a regex that no longer compiles. The 300ms debounce
            // below would otherwise leave the previous result on
            // screen until the next pause in typing.
            if regexSearch && !searchText.isEmpty {
                do {
                    _ = try NSRegularExpression(pattern: searchText, options: [.caseInsensitive])
                } catch {
                    cachedFilteredLogs = []
                    return
                }
            }
            // Debounce search keystrokes — typing in a 50k-row buffer
            // should not lock the main thread on every character.
            let task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                recomputeFilteredLogs()
            }
            searchDebounceTask = task
        }
        .onDisappear {
            // UI-R2-R07-style cleanup: cancel every Task this view
            // owns so we don't keep waking the main actor after the
            // view is torn down (detached Logs window can come and go
            // repeatedly within a session).
            searchDebounceTask?.cancel()
            regexDebounceTask?.cancel()
            actionStatusTtlTask?.cancel()
        }
        .task { logStore.start(stateManager: stateMgr) }
    }

    /// Run the filter and stash the result. Cheap on the happy path
    /// because the underlying buffer is bounded — but called only
    /// when inputs actually change, so cost doesn't multiply across
    /// body re-evaluations.
    private func recomputeFilteredLogs() {
        cachedFilteredLogs = TailViewFilter.filter(
            frames: logStore.logs,
            level: activeFilter,
            categories: selectedCategories,
            search: searchText,
            useRegex: regexSearch
        )
    }

    // MARK: - 1. detail-head

    @ViewBuilder
    private var detailHead: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIVE LOGS")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.20 * 11)
                    .foregroundStyle(C.textFaint)
                HStack(spacing: 0) {
                    Text("logs")
                        .font(.custom("InstrumentSerif-Italic", size: 38))
                        .foregroundStyle(C.signal)
                    Text(".")
                        .font(.custom("SpaceGrotesk-Bold", size: 38))
                        .foregroundStyle(C.textDim)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                PulseDot(
                    color: C.signal,
                    size: 8,
                    pulse: !prefs.reduceMotion && stateMgr.statusFrame.state == .connected
                )
                Text("\(cachedFilteredLogs.count) LINES · \(stateMgr.statusFrame.state == .connected ? "STREAMING" : "STANDBY")")
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
        HStack(spacing: 0) {
            // Pill group — joined borders
            HStack(spacing: 0) {
                ForEach(Array(LevelFilter.allCases.enumerated()), id: \.element) { idx, filter in
                    let isActive = activeFilter == filter
                    let isLast = idx == LevelFilter.allCases.count - 1
                    Button { activeFilter = filter } label: {
                        Text(filter.label)
                            .font(.custom("DepartureMono-Regular", size: 10.5))
                            .tracking(0.16 * 10.5)
                            .foregroundStyle(isActive ? C.signal : C.textDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(isActive ? C.signal.opacity(0.06) : C.bgElev)
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(isActive ? C.signalDim : C.hairBold)
                                    .frame(height: 1)
                            }
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(isActive ? C.signalDim : C.hairBold)
                                    .frame(height: 1)
                            }
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(isActive ? C.signalDim : C.hairBold)
                                    .frame(width: 1)
                            }
                            .overlay(alignment: .trailing) {
                                if isLast {
                                    Rectangle()
                                        .fill(isActive ? C.signalDim : C.hairBold)
                                        .frame(width: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Filter input
            HStack(spacing: 8) {
                TextField(regexSearch ? "filter · regex" : "filter · contains", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.custom("JetBrainsMono-Regular", size: 11.5))
                    .foregroundStyle(C.bone)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 280)
                    .focused($searchFieldFocused)
                    .overlay(
                        Rectangle().stroke(C.hairBold, lineWidth: 1)
                    )
                Button {
                    regexSearch.toggle()
                } label: {
                    Text("REGEX")
                        .font(.custom("DepartureMono-Regular", size: 10))
                        .tracking(0.16 * 10)
                        .foregroundStyle(regexSearch ? C.signal : C.textDim)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(regexSearch ? C.signal.opacity(0.06) : C.bgElev)
                        .overlay(Rectangle().stroke(regexSearch ? C.signalDim : C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Toggle regex search")
                Button {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(C.textDim)
                        .frame(width: 28, height: 28)
                        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Clear log buffer (⇧⌘⌫)")
                // UI-R4-R05: ⇧⌘⌫ (Shift+Cmd+Delete) to clear the log
                // buffer. Round 1 used ⌘K (collided with the dashboard
                // CONNECT chord), Round 2 moved to ⌘⌫ — but that
                // chord is the AppKit standard for "delete to start of
                // line" inside a TextField, so any user editing the
                // filter input could wipe the log buffer with a habit
                // keystroke. Shift+Cmd+Delete is unbound by AppKit
                // text input handling and is the macOS norm for
                // "Empty Trash" — exactly the right metaphor here.
                // We also gate the action behind a confirmation
                // dialog so even direct trash-button clicks need a
                // second tap to commit (the buffer can't be undone).
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .confirmationDialog(
                    String(localized: "logs.clear.confirm.title"),
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button(String(localized: "logs.clear.confirm.confirm"), role: .destructive) {
                        clearLogs()
                    }
                    Button(String(localized: "logs.clear.confirm.cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "logs.clear.confirm.message"))
                }
                Button {
                    copyVisibleLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(C.textDim)
                        .frame(width: 28, height: 28)
                        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Copy visible logs (⇧⌘C)")
                // UI-C3: ⇧⌘C — explicit "Copy visible logs" shortcut.
                // Plain ⌘C is deliberately left to the system so the
                // user can still copy selected text in any TextField.
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Button {
                    exportVisibleLogs()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(C.textDim)
                        .frame(width: 28, height: 28)
                        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Export visible logs (⇧⌘E)")
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button {
                    revealRuntimeLogFile()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(C.textDim)
                        .frame(width: 28, height: 28)
                        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Reveal runtime.log in Finder")
                Button {
                    followTail.toggle()
                } label: {
                    Text(followTail ? "FOLLOW" : "PAUSED")
                        .font(.custom("DepartureMono-Regular", size: 10))
                        .tracking(0.16 * 10)
                        .foregroundStyle(followTail ? C.signal : C.textDim)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(followTail ? C.signal.opacity(0.06) : C.bgElev)
                        .overlay(Rectangle().stroke(followTail ? C.signalDim : C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Toggle follow tail")
                KeyboardShortcutHint("⌘F")
                KeyboardShortcutHint("⇧⌘⌫")
                KeyboardShortcutHint("⇧⌘C")
                KeyboardShortcutHint("⇧⌘E")

                // UI-C3 hidden chord: ⌘F focuses the filter field.
                // Implemented as a zero-size Button so the SwiftUI
                // shortcut system can route the key without us
                // installing a global NSEvent monitor that hijacks
                // every ⌘C/⌘F/⌘L/⌘E in the app.
                Button {
                    focusSearchField()
                } label: {
                    EmptyView()
                }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }

    // MARK: - 2b. Category strip

    @ViewBuilder
    private var categoryStrip: some View {
        let allCategories = TailView.knownCategories
        HStack(spacing: 6) {
            Text("CATEGORY")
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.18 * 9.5)
                .foregroundStyle(C.textFaint)
            ForEach(allCategories, id: \.self) { category in
                let isOn = selectedCategories.isEmpty || selectedCategories.contains(category)
                Button {
                    toggleCategory(category, total: allCategories)
                } label: {
                    Text(category)
                        .font(.custom("DepartureMono-Regular", size: 9.5))
                        .tracking(0.14 * 9.5)
                        .foregroundStyle(isOn ? C.signal : C.textFaint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isOn ? C.signal.opacity(0.06) : C.bgElev)
                        .overlay(Rectangle().stroke(isOn ? C.signalDim : C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(isOn ? "Hide \(category) events" : "Show \(category) events")
            }
            Spacer(minLength: 0)
            if !selectedCategories.isEmpty {
                Button {
                    selectedCategories = []
                } label: {
                    Text("ALL")
                        .font(.custom("DepartureMono-Regular", size: 9.5))
                        .tracking(0.14 * 9.5)
                        .foregroundStyle(C.textDim)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Reset category filter")
            }
        }
    }

    private func toggleCategory(_ category: String, total: [String]) {
        if selectedCategories.isEmpty {
            // First click — invert: select all except the clicked one.
            selectedCategories = Set(total).subtracting([category])
            if selectedCategories.count == total.count {
                selectedCategories = []
            }
            return
        }
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
        if selectedCategories.count == total.count {
            selectedCategories = []
        }
    }

    /// Canonical category list per ADR 0008. Listed here so the strip
    /// renders in a stable order regardless of which categories actually
    /// have frames in the buffer.
    static let knownCategories: [String] = [
        "tunnel", "handshake", "stream", "packet",
        "telemetry", "tun", "ipc", "settings", "runtime", "ffi",
    ]

    @ViewBuilder
    private var tailStatusStrip: some View {
        if let status = visibleTailStatus {
            HStack(spacing: 8) {
                Image(systemName: status.iconName)
                    .font(.system(size: 12, weight: .semibold))
                Text(status.message)
                    .font(.custom("JetBrainsMono-Regular", size: 11))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tailStatusColor(status.tone))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tailStatusColor(status.tone).opacity(0.06))
            .overlay(
                Rectangle().stroke(tailStatusColor(status.tone).opacity(0.35), lineWidth: 1)
            )
        }
    }

    // MARK: - 3. tail table

    @ViewBuilder
    private var tailTable: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if cachedFilteredLogs.isEmpty {
                        Text(String(localized: "logs.empty"))
                            .font(.custom("JetBrainsMono-Regular", size: 12))
                            .foregroundStyle(C.textFaint)
                            .padding(40)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(cachedFilteredLogs.enumerated()), id: \.element.id) { idx, row in
                            tailRow(row, index: idx)
                            Rectangle().fill(C.hair.opacity(0.5)).frame(height: 1)
                        }
                    }
                    // Anchor sits OUTSIDE the conditional + AFTER the
                    // ForEach. LazyVStack only materialises the bottom
                    // anchor when it is at the tail of the layout — not
                    // wrapped inside the empty-state branch. Height is
                    // explicitly small (not 0) so SwiftUI keeps it in the
                    // layout pass even when cachedFilteredLogs is empty.
                    Color.clear
                        .frame(height: 2)
                        .id("tail-bottom")
                }
            }
            // Follow-tail: scrolling to a fixed bottom anchor is more
            // reliable than scrolling to the last row's `id` because the
            // anchor is always materialised. Defer one runloop tick so
            // the LazyVStack has actually inserted the new row first.
            //
            // UI-H8: previously two `.onChange` handlers raced on every
            // inbound log (one watched `logStore.logs.count`, one watched
            // `filteredLogs.count`). Now a single watcher on the cached
            // list — which is updated together with the source — drives
            // the scroll, animation off so follow-tail looks like a
            // ticker rather than an easing.
            .onChange(of: cachedFilteredLogs.count) { _, _ in
                guard followTail else { return }
                scrollToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: followTail) { _, isOn in
                // When the user re-enables follow tail, snap to bottom
                // immediately — otherwise the next inbound event is the
                // only thing that triggers a scroll.
                guard isOn else { return }
                scrollToBottom(proxy: proxy, animated: true)
            }
            .onAppear {
                // First reveal — jump to bottom so the user lands on the
                // freshest events even after switching tabs back.
                scrollToBottom(proxy: proxy, animated: false)
            }
        }
        .background(C.bgElev2)
        .overlay(Rectangle().stroke(C.hair, lineWidth: 1))
    }

    /// Scroll the tail table to the bottom anchor. Deferred via
    /// `DispatchQueue.main.async` so the new row is laid out before the
    /// scroll command runs (otherwise the LazyVStack hasn't inserted it
    /// yet and the anchor lands above the latest event).
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("tail-bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("tail-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func tailRow(_ row: LogFrame, index: Int) -> some View {
        let levelKey = normalizedLevel(row.level)
        let levelChip = levelChipStyle(levelKey)
        let categoryKey = row.category ?? ""
        let categoryAccent = categoryChipColor(categoryKey)
        let zebra = (index.isMultiple(of: 2)) ? Color.clear : C.bgElev.opacity(0.35)

        Button {
            copyRowAsJson(row)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Left accent strip — colored by category (or transparent).
                // Avoid `firstTextBaseline` alignment for the parent HStack:
                // a strip / chip without an intrinsic text baseline collapses
                // the row when paired with `Color.clear`. `.top` keeps the
                // row at its natural multi-line height.
                Rectangle()
                    .fill(categoryAccent.opacity(categoryKey.isEmpty ? 0 : 0.85))
                    .frame(width: 3)

                // Time column.
                Text(formatTs(row.timestampUs))
                    .font(.custom("JetBrainsMono-Regular", size: 10.5))
                    .foregroundStyle(C.textFaint)
                    .frame(width: 92, alignment: .leading)
                    .padding(.top, 1)

                // Level chip — solid bg, easy to spot.
                Text(levelKey.uppercased())
                    .font(.custom("DepartureMono-Regular", size: 9))
                    .tracking(0.18 * 9)
                    .foregroundStyle(levelChip.fg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelChip.bg)
                    .frame(minWidth: 38, alignment: .leading)

                // Category chip — outlined, color-coded by domain.
                Text(categoryKey.isEmpty ? "—" : categoryKey.uppercased())
                    .font(.custom("DepartureMono-Regular", size: 9))
                    .tracking(0.16 * 9)
                    .foregroundStyle(categoryKey.isEmpty ? C.textFaint : categoryAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        Rectangle()
                            .stroke(
                                categoryKey.isEmpty
                                    ? C.hairBold.opacity(0.6)
                                    : categoryAccent.opacity(0.55),
                                lineWidth: 1
                            )
                    )
                    .frame(minWidth: 84, alignment: .leading)

                // Message + fields.
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.msg)
                        .font(.custom("JetBrainsMono-Regular", size: 11))
                        .foregroundStyle(messageColor(levelKey))
                        .textSelection(.enabled)
                    if let summary = renderFields(row.fields), !summary.isEmpty {
                        Text(summary)
                            .font(.custom("JetBrainsMono-Regular", size: 10))
                            .foregroundStyle(C.textFaint)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(zebra)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy this row as JSON")
    }

    /// Solid level badge — high contrast for ERR/WRN, soft tint for the
    /// rest. Mapping covers normalised keys produced by
    /// `TunnelLogStore.normalizedLevel`.
    private func levelChipStyle(_ level: String) -> (fg: Color, bg: Color) {
        switch level {
        case "error": return (Color.white,         C.danger)
        case "warn":  return (Color.black.opacity(0.88), C.warn)
        case "ok":    return (C.signal,            C.signal.opacity(0.18))
        case "info":  return (C.signal,            C.signal.opacity(0.10))
        case "debug": return (C.blueDebug,         C.blueDebug.opacity(0.16))
        case "trace": return (C.textFaint,         C.bgElev)
        default:      return (C.textDim,           C.bgElev)
        }
    }

    /// Stable colour per ADR-0008 category. Picked for distinguishability
    /// at small chip size on both dark and light palettes — none of these
    /// duplicate the level palette (signal/warn/danger) so message and
    /// category never read the same colour.
    private func categoryChipColor(_ category: String) -> Color {
        switch category {
        case "tunnel":    return C.signal
        case "handshake": return C.warn
        case "stream":    return C.blueDebug
        case "packet":    return Color(hex: 0xFF8B7AC0)   // lavender
        case "telemetry": return Color(hex: 0xFF4DB6AC)   // teal
        case "tun":       return Color(hex: 0xFFFF8A65)   // coral
        case "ipc":       return C.textDim
        case "settings":  return C.bone
        case "runtime":   return C.danger
        case "ffi":       return C.textFaint
        default:          return C.textDim
        }
    }

    /// Slightly tone down the message colour for low-priority levels so
    /// the eye stays on warn/error rows. Bone for everything ≥ INF, dim
    /// for DBG, faint for TRC.
    private func messageColor(_ level: String) -> Color {
        switch level {
        case "trace": return C.textFaint
        case "debug": return C.textDim
        default:      return C.bone
        }
    }

    private func renderFields(_ fields: [String: String]?) -> String? {
        guard let fields, !fields.isEmpty else { return nil }
        return fields.keys.sorted()
            .map { "\($0)=\(fields[$0] ?? "")" }
            .joined(separator: " ")
    }

    private func copyRowAsJson(_ row: LogFrame) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(row),
              let json = String(data: data, encoding: .utf8) else {
            setActionStatus(TailStatus(message: "Could not encode row to JSON", tone: .danger))
            return
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(json, forType: .string) else {
            setActionStatus(TailStatus(message: "Pasteboard rejected the copy", tone: .danger))
            return
        }
        setActionStatus(TailStatus(message: "Copied 1 log row as JSON", tone: .info))
    }

    private func revealRuntimeLogFile() {
        // ADR 0008 §4: resolve through `PhantomKit.LogPathResolver` —
        // the same source the extension's `LogFileWriter` writes to,
        // so this button always lands on the file the writer produces.
        let url = LogPathResolver.defaultRuntimeLogURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            setActionStatus(TailStatus(message: "Revealed runtime.log in Finder", tone: .info))
            return
        }

        let dirUrl = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dirUrl.path) {
            NSWorkspace.shared.open(dirUrl)
            setActionStatus(TailStatus(
                message: "runtime.log not yet created — opened log folder",
                tone: .warning
            ))
        } else {
            setActionStatus(TailStatus(
                message: "Log folder not yet created — start the tunnel first",
                tone: .warning
            ))
        }
    }

    // MARK: - Helpers

    private var activeSearchRegex: NSRegularExpression? {
        guard regexSearch, !searchText.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: searchText, options: [.caseInsensitive])
    }

    private var regexSearchError: String? {
        guard regexSearch, !searchText.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: searchText, options: [.caseInsensitive])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var visibleTailStatus: TailStatus? {
        if let regexSearchError {
            return TailStatus(message: "Invalid regex: \(regexSearchError)", tone: .danger)
        }
        if let actionStatus, actionStatus.tone != .info {
            return actionStatus
        }
        if let lastErrorMessage = logStore.lastErrorMessage {
            return TailStatus(message: lastErrorMessage, tone: .danger)
        }
        return actionStatus
    }

    private func matchesSearch(_ row: LogFrame, regex: NSRegularExpression?) -> Bool {
        guard !searchText.isEmpty else { return true }
        let haystack = "\(row.level) \(row.msg)"
        guard regexSearch else {
            return haystack.localizedCaseInsensitiveContains(searchText)
        }
        guard let regex else { return false }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }

    private func copyVisibleLogs() {
        let output = renderVisibleLogs()
        guard !output.isEmpty else {
            setActionStatus(TailStatus(message: "No visible log lines to copy", tone: .warning))
            return
        }

        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(output, forType: .string) else {
            setActionStatus(TailStatus(message: "Copy failed: pasteboard rejected the log text", tone: .danger))
            return
        }
        setActionStatus(TailStatus(message: "Copied \(cachedFilteredLogs.count) visible log lines", tone: .info))
    }

    private func clearLogs() {
        logStore.clear()
        setActionStatus(TailStatus(message: "Cleared log buffer", tone: .info))
    }

    private func clearFilters() {
        activeFilter = .all
        searchText = ""
        regexSearch = false
        setActionStatus(TailStatus(message: "Cleared log filters", tone: .info))
        focusSearchField()
    }

    private func focusSearchField() {
        searchFieldFocused = true
        DispatchQueue.main.async {
            searchFieldFocused = true
        }
    }

    /// UI-R2-N02: action banner with TTL. Info-tone banners auto-clear
    /// after 5s so a successful "Copied N lines" doesn't sit on screen
    /// forever (and gradually accrue visual weight like a warning).
    /// Warning/danger banners stick until the next action so the user
    /// has time to read them. Cancels any pending TTL task before
    /// re-arming.
    private func setActionStatus(_ status: TailStatus) {
        actionStatus = status
        actionStatusTtlTask?.cancel()
        guard status.tone == .info else { return }
        let captured = status
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            // Only clear if we still own this banner — a later action
            // may have replaced it.
            if let current = actionStatus,
               current.message == captured.message,
               current.tone == captured.tone {
                actionStatus = nil
            }
        }
        actionStatusTtlTask = task
    }

    // UI-C3/C6/H11: shortcut handling moved to per-button SwiftUI
    // `.keyboardShortcut(...)` modifiers (⇧⌘C copy, ⇧⌘E export, ⌘K
    // clear, ⌘F focus filter). SwiftUI scopes shortcuts to the
    // hosting window's responder chain, so the previous
    // `NSEvent.addLocalMonitorForEvents` global monitor — which
    // hijacked Copy/Find for every TextField in the app and would
    // double-fire when a detached Logs window was open — is
    // deliberately removed.

    private func exportVisibleLogs() {
        let output = renderVisibleLogs()
        guard !output.isEmpty else {
            setActionStatus(TailStatus(message: "No visible log lines to export", tone: .warning))
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ghoststream-logs-\(Int(Date().timeIntervalSince1970)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
            setActionStatus(TailStatus(message: "Exported \(cachedFilteredLogs.count) visible log lines", tone: .info))
        } catch {
            setActionStatus(TailStatus(message: "Export failed: \(error.localizedDescription)", tone: .danger))
        }
    }

    private func renderVisibleLogs() -> String {
        cachedFilteredLogs.map(formatLogLine).joined(separator: "\n")
    }

    private func formatLogLine(_ row: LogFrame) -> String {
        let categoryPart = (row.category?.isEmpty ?? true) ? "" : " [\(row.category!)]"
        let fieldsPart = renderFields(row.fields).map { " {\($0)}" } ?? ""
        return "\(formatTs(row.timestampUs)) [\(normalizedLevel(row.level))]\(categoryPart) \(row.msg)\(fieldsPart)"
    }

    private func levelColor(_ level: String) -> Color {
        switch normalizedLevel(level) {
        case "error": return C.danger
        case "warn":  return C.warn
        case "info":  return C.textDim
        case "ok":    return C.signal
        case "debug": return C.blueDebug
        default:      return C.textDim
        }
    }

    private func normalizedLevel(_ level: String) -> String {
        TunnelLogStore.normalizedLevel(level)
    }

    private func tailStatusColor(_ tone: TailStatusTone) -> Color {
        switch tone {
        case .info:    return C.signal
        case .warning: return C.warn
        case .danger:  return C.danger
        }
    }

    private func formatTs(_ tsUs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(tsUs) / 1_000_000.0)
        return Self.timestampFormatter.string(from: date)
    }
}

/// Pure filter logic extracted for testability. Keeps the SwiftUI view
/// state-free of business rules — see `LogFrameFilterTests` (when a
/// macOS-app test target lands).
enum TailViewFilter {
    static func filter(
        frames: [LogFrame],
        level: LevelFilter,
        categories: Set<String>,
        search: String,
        useRegex: Bool
    ) -> [LogFrame] {
        let regex: NSRegularExpression?
        if useRegex && !search.isEmpty {
            regex = try? NSRegularExpression(pattern: search, options: [.caseInsensitive])
            if regex == nil { return [] }
        } else {
            regex = nil
        }

        return frames.filter { frame in
            let normalized = normalize(level: frame.level)
            let levelOk = level == .all || normalized == level.matchKey
            let categoryOk = categories.isEmpty
                || (frame.category.map { categories.contains($0) } ?? false)
            let textOk = matches(frame: frame, search: search, regex: regex, useRegex: useRegex)
            return levelOk && categoryOk && textOk
        }
    }

    /// Pure, isolation-free copy of `TunnelLogStore.normalizedLevel` so
    /// the filter compiles outside the main actor. Both implementations
    /// share the same mapping table — keep them in sync.
    static func normalize(level: String) -> String {
        switch level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "inf", "info":
            return "info"
        case "wrn", "warn", "warning":
            return "warn"
        case "err", "error":
            return "error"
        case "dbg", "debug", "trc", "trace":
            return "debug"
        case "ok", "success":
            return "ok"
        default:
            return "info"
        }
    }

    private static func matches(
        frame: LogFrame,
        search: String,
        regex: NSRegularExpression?,
        useRegex: Bool
    ) -> Bool {
        guard !search.isEmpty else { return true }

        var haystack = "\(frame.level) \(frame.msg)"
        if let category = frame.category {
            haystack.append(" \(category)")
        }
        if let fields = frame.fields, !fields.isEmpty {
            for (k, v) in fields {
                haystack.append(" \(k)=\(v)")
            }
        }

        guard useRegex else {
            return haystack.localizedCaseInsensitiveContains(search)
        }
        guard let regex else { return false }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }
}

private struct TailStatus {
    let message: String
    let tone: TailStatusTone

    var iconName: String {
        switch tone {
        case .info:    return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .danger:  return "xmark.octagon"
        }
    }
}

private enum TailStatusTone: Equatable {
    case info
    case warning
    case danger
}

enum LevelFilter: String, CaseIterable {
    case all, info, warn, error, debug

    var label: String {
        switch self {
        case .all:   return "all"
        case .info:  return "info"
        case .warn:  return "warn"
        case .error: return "error"
        case .debug: return "debug"
        }
    }

    var matchKey: String {
        switch self {
        case .all:   return "*"
        case .info:  return "info"
        case .warn:  return "warn"
        case .error: return "error"
        case .debug: return "debug"
        }
    }
}
