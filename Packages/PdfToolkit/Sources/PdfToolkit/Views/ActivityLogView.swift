import SwiftUI
import AppKit

/// The Activity Log window: the app's record of every file-changing operation. Shows
/// `ActivityLog.shared`'s live in-memory stream — day-grouped, filterable by level, searchable — and
/// can load older entries straight from `~/pdf-utils.log`. Built in the shape of SyncCloud's
/// `LogViewer` (the "same UX" the port targets) using pdf-utils' own glass + density helpers.
public struct ActivityLogView: View {
    @ObservedObject private var log = ActivityLog.shared

    public init() {}

    /// The severity threshold to show (not exact-match). nil = All Levels.
    @State private var selectedLevel: LogLevel? = nil
    @State private var searchText: String = ""

    /// Previous-session entries pulled from the log file on demand (newest-first). nil until the user
    /// asks via "Show older history"; an empty array means the file holds nothing older.
    @State private var loadedHistory: [LogEntry]? = nil
    @State private var historyLimit = ActivityLogView.historyPageSize
    @State private var isLoadingHistory = false

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlass.defaultHue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var glassTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? LiquidGlass.defaultHue }
    private var hueAccent: Color { glassHue.accentColor }
    private var density: ListDensity { ListDensity(rawValue: listDensityRaw) ?? .comfortable }

    /// Page size for on-demand history: the first "Show older history" reveals this many, and each
    /// "Show more" reveals another page.
    private static let historyPageSize = 25

    /// Short labels for the severity threshold chips — same thresholds as the picker menu.
    private static let chipOptions: [(label: String, level: LogLevel?)] = [
        ("All", nil),
        ("Info", .info),
        ("Warnings", .warning),
        ("Errors", .error),
    ]

    /// One O(N) pass tallying how many entries sit at or above each chip threshold (plus the total
    /// under the `nil`/"All" key), computed once per body render.
    private static func thresholdCounts(_ entries: [LogEntry]) -> [LogLevel?: Int] {
        var perLevel: [LogLevel: Int] = [:]
        for entry in entries { perLevel[entry.level, default: 0] += 1 }
        var out: [LogLevel?: Int] = [nil: entries.count]
        for option in chipOptions {
            guard let level = option.level else { continue }
            out[level] = perLevel.reduce(0) { $0 + ($1.key.severity >= level.severity ? $1.value : 0) }
        }
        return out
    }

    public var body: some View {
        // Computed once per body evaluation, shared by the count badges and the list.
        let filtered = ActivityLogFilter.apply(log.entries, minimumLevel: selectedLevel, search: searchText)
        let counts = Self.thresholdCounts(log.entries)
        let historyMatches = loadedHistory.map { ActivityLogFilter.matches($0, minimumLevel: selectedLevel, search: searchText) } ?? []
        let visibleHistory = Array(historyMatches.prefix(historyLimit))
        let moreHistory = historyMatches.count > historyLimit

        VStack(spacing: 0) {
            toolbar(filtered: filtered)
            Divider().opacity(0.6)
            levelChips(counts: counts)
            searchBar
            Divider().opacity(0.6)
            list(filtered: filtered, visibleHistory: visibleHistory, moreHistory: moreHistory)
        }
        .frame(minWidth: 420, minHeight: 420)
        .liquidGlassAppBackground(level: glassLevel, hue: glassHue)
        .onChange(of: selectedLevel) { _, _ in historyLimit = Self.historyPageSize }
        .onChange(of: searchText) { _, _ in historyLimit = Self.historyPageSize }
    }

    // MARK: Toolbar

    @ViewBuilder
    private func toolbar(filtered: [LogEntry]) -> some View {
        HStack(spacing: 10) {
            Text("Activity Log")
                .font(.headline)
            Spacer()

            Button {
                listDensityRaw = (density == .compact ? ListDensity.comfortable : .compact).rawValue
            } label: {
                Image(systemName: density == .compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(density == .compact ? "Use comfortable rows" : "Use compact rows")
            .accessibilityLabel(density == .compact ? "Switch to comfortable rows" : "Switch to compact rows")

            Button {
                copyToPasteboard(filtered)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(filtered.isEmpty)
            .help("Copy the \(filtered.count) shown \(filtered.count == 1 ? "entry" : "entries") to the clipboard")

            Button {
                log.clearLogs()
                loadedHistory = nil
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(log.entries.isEmpty)
            .help("Clear the log")

            Button {
                log.openLogFile()
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open \(log.fileURL.lastPathComponent) in the default editor")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassBarStyle(level: glassLevel)
    }

    // MARK: Level chips

    @ViewBuilder
    private func levelChips(counts: [LogLevel?: Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.chipOptions, id: \.label) { option in
                    levelChip(option.label, level: option.level, count: counts[option.level] ?? 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func levelChip(_ label: String, level: LogLevel?, count: Int) -> some View {
        let selected = selectedLevel == level
        let onAccent = Color.onFillLabel(hueAccent)
        Button {
            selectedLevel = level
        } label: {
            HStack(spacing: 5) {
                Text(label)
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(selected ? AnyShapeStyle(onAccent.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? AnyShapeStyle(onAccent) : AnyShapeStyle(.primary))
            .background(
                Capsule().fill(selected ? AnyShapeStyle(hueAccent) : AnyShapeStyle(Color.secondary.opacity(0.12)))
            )
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: selected ? 0 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show \(label.lowercased())")
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by message…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(12)
        .glassBarStyle(level: glassLevel)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: List

    @ViewBuilder
    private func list(filtered: [LogEntry], visibleHistory: [LogEntry], moreHistory: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: density == .compact ? 0 : 2) {
                if filtered.isEmpty && visibleHistory.isEmpty {
                    emptyState
                } else {
                    daySections(filtered)
                }
                historyFooter(visibleHistory: visibleHistory, moreAvailable: moreHistory)
            }
            .padding(16)
        }
        .background(.regularMaterial.opacity(0.5))
    }

    @ViewBuilder
    private func daySections(_ entries: [LogEntry]) -> some View {
        ForEach(ActivityLogGrouping.byDay(entries)) { section in
            ActivityLogDayHeader(text: section.header)
            ForEach(section.items) { entry in
                ActivityLogRow(entry: entry, density: density)
            }
        }
    }

    // MARK: History footer

    @ViewBuilder
    private func historyFooter(visibleHistory: [LogEntry], moreAvailable: Bool) -> some View {
        if let loadedHistory {
            if !visibleHistory.isEmpty {
                historyDivider
                daySections(visibleHistory)
                if moreAvailable {
                    historyActionButton("Show \(Self.historyPageSize) more", icon: "chevron.down") {
                        historyLimit += Self.historyPageSize
                    }
                } else {
                    historyEndNote("No older entries — you're at the start of the log")
                }
            } else if loadedHistory.isEmpty {
                historyEndNote("No earlier activity in the log")
            }
            // else: history exists but the filter hides it — the session rows already explain emptiness.
        } else {
            historyActionButton("Show older history", icon: "clock.arrow.circlepath",
                                loading: isLoadingHistory) { loadHistory() }
        }
    }

    private var historyDivider: some View {
        HStack(spacing: 8) {
            VStack { Divider().opacity(0.5) }
            Text("Earlier sessions")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .fixedSize()
            VStack { Divider().opacity(0.5) }
        }
        .padding(.vertical, 6)
    }

    private func historyActionButton(_ title: String, icon: String, loading: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                HStack(spacing: 6) {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: icon)
                    }
                    Text(loading ? "Loading…" : title)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(loading)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func historyEndNote(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 10)
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        let hasRawEntries = !log.entries.isEmpty || !(loadedHistory?.isEmpty ?? true)
        if hasRawEntries {
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matching entries",
                message: "The current level filter and search hide every entry. Clear them to see the log again.",
                primary: .init("Clear Filters", systemImage: "xmark.circle") {
                    selectedLevel = nil
                    searchText = ""
                }
            )
            .frame(minHeight: 220)
        } else if loadedHistory != nil {
            EmptyStateView(
                icon: "clock",
                title: "No activity recorded",
                message: "This session is quiet and the log holds nothing from earlier sessions. Every merge, split, rotate, and other file change appears here as it happens."
            )
            .frame(minHeight: 220)
        } else {
            EmptyStateView(
                icon: "list.bullet.rectangle",
                title: "No activity yet",
                message: "Every operation that writes a PDF is recorded here — with its destination and size. This session is quiet so far; use “Show older history” below to load what earlier sessions recorded.",
                secondary: .init("Reveal Log File", systemImage: "doc.text") {
                    NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
                }
            )
            .frame(minHeight: 220)
        }
    }

    // MARK: Actions

    /// Copies the on-screen slice to the clipboard as canonical log lines. Emitted oldest-first so
    /// the paste reads chronologically and matches the file's order (the list shows newest-first).
    private func copyToPasteboard(_ entries: [LogEntry]) {
        let text = entries.reversed().map(\.formattedString).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Reads previous-session history off the main actor and reveals the first page. The file is read
    /// from this session's fixed start backwards, but that boundary alone isn't enough to avoid
    /// duplicates: `ActivityLog` seeds its live mirror with the tail of the previous run (so a relaunch
    /// isn't blank), and those seeded lines are also `< sessionStart`. So we additionally drop any
    /// loaded line already visible in the live list — leaving history to show only what predates it.
    private func loadHistory() {
        guard !isLoadingHistory, loadedHistory == nil else { return }
        isLoadingHistory = true
        let boundary = log.sessionStart
        let fileURL = log.fileURL
        // Snapshot what's already on screen (canonical line form encodes timestamp+level+message).
        let alreadyShown = Set(log.entries.map(\.formattedString))
        Task {
            let history = await Task.detached(priority: .userInitiated) {
                ActivityLogHistory.loadOlderThan(boundary, excluding: alreadyShown, fileURL: fileURL)
            }.value
            historyLimit = Self.historyPageSize
            loadedHistory = history
            isLoadingHistory = false
        }
    }
}

// MARK: - Day grouping

/// Splits entries (already in newest-first display order) into per-day sections with a "Today" /
/// "Yesterday" / date header. A lighter analogue of SyncCloud's `LogGrouping` — no operation-run
/// folding, since each pdf-utils operation is a single line.
enum ActivityLogGrouping {
    struct DaySection: Identifiable {
        let id: String
        let header: String
        var items: [LogEntry]
    }

    static func byDay(_ entries: [LogEntry], now: Date = Date(), calendar: Calendar = .current) -> [DaySection] {
        var sections: [DaySection] = []
        for entry in entries {
            let dayStart = calendar.startOfDay(for: entry.timestamp)
            let key = Self.keyFormatter.string(from: dayStart)
            if var last = sections.last, last.id == key {
                last.items.append(entry)
                sections[sections.count - 1] = last
            } else {
                sections.append(DaySection(id: key, header: header(for: dayStart, now: now, calendar: calendar), items: [entry]))
            }
        }
        return sections
    }

    private static func header(for dayStart: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(dayStart) { return "Today" }
        if calendar.isDateInYesterday(dayStart) { return "Yesterday" }
        return Self.displayFormatter.string(from: dayStart)
    }

    /// Stable day key (pinned locale/calendar so it groups the same regardless of system settings).
    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Rows

/// A day divider ("Today" / "Yesterday" / a date) above that day's rows.
private struct ActivityLogDayHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.4)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// One row rendering a single `LogEntry`: a color-coded severity glyph, a level badge + time, the
/// message, and (for warnings/errors) a dimmed location caption. Compact collapses to one baseline.
/// When the entry recorded a save whose destination still exists on disk, the row reveals a
/// Reveal-in-Finder / Open pair on hover and offers the same via right-click.
struct ActivityLogRow: View {
    let entry: LogEntry
    var density: ListDensity = .comfortable

    @State private var isHovering = false

    /// The saved destination's URL, but only when the entry carries a structured path AND that path
    /// still exists — the gate for showing the Reveal/Open actions. Recomputed per body pass; a stat
    /// call on a lazily-rendered row is cheap, and it means a since-deleted file drops its actions.
    private var existingFileURL: URL? {
        guard let path = entry.path else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    var body: some View {
        let fileURL = existingFileURL
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.level.icon)
                .font(.caption)
                .foregroundStyle(entry.level.color)
                .frame(width: 18)
                .padding(.top, 2)

            if density == .compact {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    levelBadge
                    timeText
                    messageText.lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        levelBadge
                        timeText
                    }
                    messageText
                    if let location = entry.messageLocation {
                        Text(location)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)

            if let fileURL {
                fileActions(url: fileURL)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
            }
        }
        .padding(.vertical, density.rowVerticalPadding)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if let fileURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button {
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
            }
        }
    }

    /// The hover-revealed Reveal/Open pair, styled as unobtrusive borderless glyphs so it sits
    /// quietly at the row's trailing edge until pointed at.
    @ViewBuilder
    private func fileActions(url: URL) -> some View {
        HStack(spacing: 2) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open")
            .accessibilityLabel("Open")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 1)
    }

    private var levelBadge: some View {
        Text(entry.level.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(entry.level.color.opacity(0.16)))
            .foregroundStyle(entry.level.color)
    }

    private var timeText: some View {
        Text(Self.timeFormatter.string(from: entry.timestamp))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var messageText: some View {
        Text(entry.messageBody)
            .font(.system(.subheadline, design: .monospaced))
            .textSelection(.enabled)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
