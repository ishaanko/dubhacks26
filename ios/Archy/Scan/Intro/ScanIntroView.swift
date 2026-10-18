import SwiftUI

/// The Scan tab at rest: how a scan works in one glance, previous scans, then Start (or a sample on devices without LiDAR).
@MainActor
struct ScanIntroView: View {
    let isSupported: Bool
    let previous: [SavedScan]
    let onStart: () -> Void
    let onSample: () -> Void
    let onTips: () -> Void
    let onImport: () -> Void
    let onOpen: (SavedScan) -> Void
    let onProcess: (SavedScan) -> Void
    let onDelete: (SavedScan) -> Void
    /// Opens scrolled to Previous scans (the `scan.previous` debug route, for screenshots).
    var startsAtEnd = false

    @AppStorage(MeasurementUnit.storageKey) private var unit = MeasurementUnit.localeDefault()
    @State private var pendingDelete: SavedScan?

    private static let tips = [
        "Ask someone to hold the phone.",
        "Stand barefoot on a plain floor.",
        "Two slow laps around your foot.",
    ]

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Text("Scan your foot")
                    .display(.hero)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, Space.sm)
                    .reveal(0)
                    .introRow()
                PositioningDiagram()
                    .reveal(1)
                    .introRow()
                VStack(spacing: 0) {
                    ForEach(Array(Self.tips.enumerated()), id: \.offset) { index, tip in
                        if index > 0 { Hairline() }
                        Text(tip)
                            .foregroundStyle(.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Space.md)
                    }
                }
                .reveal(2)
                .introRow()
                previousScans
            }
            .onChange(of: previous.count) {
                if startsAtEnd, let last = previous.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { actions.reveal(3) }
        .confirmationDialog("Delete this scan?", isPresented: deleting, titleVisibility: .visible, presenting: pendingDelete) { scan in
            Button("Delete", role: .destructive) { onDelete(scan) }
        } message: { scan in
            Text(scan.unprocessedPhotos == nil ? "Its model and photos are removed from this iPhone." : "Its photos are removed from this iPhone.")
        }
    }

    private var deleting: Binding<Bool> {
        Binding { pendingDelete != nil } set: { if !$0 { pendingDelete = nil } }
    }

    // MARK: Previous scans

    @ViewBuilder
    private var previousScans: some View {
        if previous.isEmpty {
            Button("Import a scan", action: onImport)
                .buttonStyle(.archyGhost)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("scan.import")
                .introRow()
        } else {
            HStack {
                Text("Previous scans").display(.headline)
                Spacer()
                Button("Import a scan", action: onImport)
                    .buttonStyle(.archyGhost)
                    .font(.subheadline)
                    .accessibilityIdentifier("scan.import")
            }
            .padding(.top, Space.md)
            .introRow()
            ForEach(previous) { scan in
                previousRow(scan)
                    .buttonStyle(.archyPressable)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden, edges: .top)
                    .listRowSeparatorTint(.line2)
                    .listRowInsets(EdgeInsets(top: 0, leading: Space.page, bottom: 0, trailing: Space.page))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { pendingDelete = scan }
                    }
            }
        }
    }

    /// A finished scan opens in the viewer; one whose photos were never processed builds its model.
    @ViewBuilder
    private func previousRow(_ scan: SavedScan) -> some View {
        if let photos = scan.unprocessedPhotos {
            Button { onProcess(scan) } label: { unprocessedRow(scan.date, photos: photos) }
                .accessibilityIdentifier("scan.process")
        } else {
            Button { onOpen(scan) } label: { row(scan) }
                .accessibilityIdentifier("scan.previous")
        }
    }

    private func dateColumn(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.footnote)
                .foregroundStyle(.inkSecondary)
        }
    }

    /// Date and time, the photo count, and Process where a finished scan has its chevron.
    private func unprocessedRow(_ date: Date, photos: Int) -> some View {
        HStack(spacing: Space.md) {
            dateColumn(date)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(photos) photos").monospacedDigit()
                Text("Not processed")
                    .font(.footnote)
                    .foregroundStyle(.inkSecondary)
            }
            Text("Process").font(.subheadline.weight(.semibold))
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    /// Date and time, then the length and arch once measured.
    private func row(_ scan: SavedScan) -> some View {
        HStack(spacing: Space.md) {
            dateColumn(scan.date)
            Spacer()
            if let length = scan.summary?.lengthMM, let isFlat = scan.summary?.isFlat {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(unit.format(millimeters: length)).monospacedDigit()
                    Text(isFlat ? "Flat arch" : "Normal arch")
                        .font(.footnote)
                        .foregroundStyle(.inkSecondary)
                }
            } else if scan.summary != nil {
                Text("Arch not measured")
                    .font(.footnote)
                    .foregroundStyle(.inkSecondary)
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.inkTertiary)
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Space.sm) {
            if isSupported {
                Button("Start scan", action: onStart)
                    .buttonStyle(.archyPrimary)
                    .accessibilityIdentifier("scan.start")
                HStack {
                    Button("How to scan", action: onTips)
                    Button("View a sample", action: onSample)
                        .accessibilityIdentifier("scan.sample")
                }
                .buttonStyle(.archyGhost)
            } else {
                Text("Scanning needs an iPhone with LiDAR.")
                    .font(.callout)
                    .foregroundStyle(.inkSecondary)
                Button("View a sample scan", action: onSample)
                    .buttonStyle(.archyPrimary)
                    .accessibilityIdentifier("scan.sample")
                Button("How to scan", action: onTips)
                    .buttonStyle(.archyGhost)
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.sm)
        .frame(maxWidth: .infinity)
        .background(Color.bg)
    }
}

private extension View {
    /// A plain, separator-free list row at the page margins.
    func introRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Space.sm, leading: Space.page, bottom: Space.sm, trailing: Space.page))
    }
}
