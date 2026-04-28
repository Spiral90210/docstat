import Foundation
import SwiftUI

enum SortColumn {
    case name, cpu, mem, memPercent
}

@MainActor
final class StatsViewModel: ObservableObject {
    @Published var rows: [ContainerStats] = []
    @Published var status: String? = "Loading..."
    @Published var sortColumn: SortColumn = .cpu
    @Published var sortAscending: Bool = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var systemMemTotal: UInt64?

    private let client = DockerClient()

    var totalCpuPercent: Double { rows.reduce(0) { $0 + $1.cpuPercent } }
    var totalMemBytes: UInt64 { rows.reduce(0) { $0 + $1.memBytes } }
    var totalMemPercent: Double { rows.reduce(0) { $0 + $1.memPercent } }

    func disconnect() async {
        await client.disconnect()
    }

    func toggleSort(_ column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = (column == .name)
        }
        applySort()
    }

    private func applySort() {
        switch sortColumn {
        case .name:
            rows.sort { a, b in
                let r = a.name.localizedCaseInsensitiveCompare(b.name)
                return sortAscending ? r == .orderedAscending : r == .orderedDescending
            }
        case .cpu:
            rows.sort { sortAscending ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent }
        case .mem:
            rows.sort { sortAscending ? $0.memBytes < $1.memBytes : $0.memBytes > $1.memBytes }
        case .memPercent:
            rows.sort { sortAscending ? $0.memPercent < $1.memPercent : $0.memPercent > $1.memPercent }
        }
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let containers = try await client.listContainers()
            self.systemMemTotal = (try? await client.info())?.MemTotal
            if containers.isEmpty {
                self.rows = []
                self.status = "No running containers"
                return
            }

            let collected = await withTaskGroup(of: ContainerStats?.self) { group -> [ContainerStats] in
                for c in containers {
                    let id = c.Id
                    let displayName = (c.Names.first ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    group.addTask { [client] in
                        do {
                            let snapshot = try await client.stats(for: id)
                            return Self.normalize(id: id, name: displayName, snapshot: snapshot)
                        } catch {
                            return nil
                        }
                    }
                }
                var results: [ContainerStats] = []
                for await item in group {
                    if let item { results.append(item) }
                }
                return results
            }

            self.rows = collected
            applySort()
            self.status = nil
        } catch {
            self.rows = []
            self.systemMemTotal = nil
            self.status = "Docker not running"
        }
    }

    nonisolated private static func normalize(id: String, name: String, snapshot: DockerStatsResponse) -> ContainerStats {
        let totalUsage = snapshot.cpu_stats.cpu_usage.total_usage
        let preTotal = snapshot.precpu_stats.cpu_usage.total_usage
        let cpuDelta: Int64 = Int64(totalUsage) - Int64(preTotal)

        let systemUsage = snapshot.cpu_stats.system_cpu_usage ?? 0
        let preSystem = snapshot.precpu_stats.system_cpu_usage ?? 0
        let systemDelta: Int64 = Int64(systemUsage) - Int64(preSystem)

        let onlineCpus = snapshot.cpu_stats.online_cpus
            ?? snapshot.cpu_stats.cpu_usage.percpu_usage?.count
            ?? 1

        let cpuPercent: Double
        if systemDelta > 0 && cpuDelta > 0 {
            cpuPercent = (Double(cpuDelta) / Double(systemDelta)) * Double(onlineCpus) * 100.0
        } else {
            cpuPercent = 0.0
        }

        let usage = snapshot.memory_stats.usage ?? 0
        let cache = snapshot.memory_stats.stats?.cache ?? 0
        let used: UInt64 = usage > cache ? usage - cache : usage
        let limit = snapshot.memory_stats.limit ?? 0
        let memPercent: Double = limit > 0 ? (Double(used) / Double(limit)) * 100.0 : 0.0

        return ContainerStats(
            id: id,
            name: name,
            cpuPercent: cpuPercent,
            memBytes: used,
            memPercent: memPercent
        )
    }
}
