import Foundation

struct ContainerStats: Identifiable, Hashable {
    let id: String
    let name: String
    let cpuPercent: Double
    let memBytes: UInt64
    let memPercent: Double
}
