import SwiftUI

struct PopoverView: View {
    @ObservedObject var viewModel: StatsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
        }
        .padding(16)
        .frame(width: 480, height: 360)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            stat(label: "CPU%", value: String(format: "%.1f", viewModel.totalCpuPercent))
            stat(label: "Mem", value: memValue)
            stat(label: "Mem%", value: String(format: "%.1f", viewModel.totalMemPercent))
            Spacer()
            ZStack {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .opacity(viewModel.isRefreshing ? 0 : 1)
                .disabled(viewModel.isRefreshing)

                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(1.2)
                }
            }
            .frame(width: 24, height: 24)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
        }
        .frame(height: 44)
    }

    private var memValue: String {
        let used = formatBytes(viewModel.totalMemBytes)
        if let total = viewModel.systemMemTotal {
            return "\(used) / \(formatBytes(total))"
        }
        return used
    }

    private func stat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let status = viewModel.status {
            VStack {
                Spacer()
                Text(status)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                tableHeader
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.rows) { row in
                            StatRow(row: row)
                        }
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            headerCell("Name", column: .name, trailing: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell("CPU %", column: .cpu, trailing: true)
                .frame(width: 70)
            headerCell("Mem", column: .mem, trailing: true)
                .frame(width: 90)
            headerCell("Mem %", column: .memPercent, trailing: true)
                .frame(width: 70)
        }
        .padding(.vertical, 6)
    }

    private func headerCell(_ title: String, column: SortColumn, trailing: Bool) -> some View {
        Button {
            viewModel.toggleSort(column)
        } label: {
            HStack(spacing: 4) {
                if trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.sortColumn == column {
                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !trailing { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StatRow: View {
    let row: ContainerStats
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f", row.cpuPercent))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(formatBytes(row.memBytes))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Text(String(format: "%.1f", row.memPercent))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .fontWeight(hovering ? .bold : .regular)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
