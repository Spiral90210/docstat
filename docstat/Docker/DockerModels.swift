import Foundation

struct DockerContainerListEntry: Decodable {
    let Id: String
    let Names: [String]
}

struct DockerStatsResponse: Decodable {
    struct CPUStats: Decodable {
        struct CPUUsage: Decodable {
            let total_usage: UInt64
            let percpu_usage: [UInt64]?
        }
        let cpu_usage: CPUUsage
        let system_cpu_usage: UInt64?
        let online_cpus: Int?
    }

    struct MemoryStats: Decodable {
        struct Stats: Decodable {
            let cache: UInt64?
        }
        let usage: UInt64?
        let limit: UInt64?
        let stats: Stats?
    }

    let cpu_stats: CPUStats
    let precpu_stats: CPUStats
    let memory_stats: MemoryStats
}
