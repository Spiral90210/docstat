import Foundation
import Network

enum DockerClientError: Error {
    case socketUnavailable
    case connectionFailed
    case invalidResponse
    case httpStatus(Int)
}

actor DockerClient {
    private let socketPath: String?
    private let queue = DispatchQueue(label: "docstat.docker.socket")
    private let decoder = JSONDecoder()
    private var connection: NWConnection?
    private var rxBuffer = Data()

    init() {
        self.socketPath = DockerClient.resolveSocketPath()
    }

    private static func resolveSocketPath() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.docker/run/docker.sock",
            "/var/run/docker.sock"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    func listContainers() async throws -> [DockerContainerListEntry] {
        let body = try await request(path: "/containers/json")
        return try decoder.decode([DockerContainerListEntry].self, from: body)
    }

    func stats(for containerId: String) async throws -> DockerStatsResponse {
        let body = try await request(path: "/containers/\(containerId)/stats?stream=false")
        return try decoder.decode(DockerStatsResponse.self, from: body)
    }

    private func request(path: String) async throws -> Data {
        guard let socketPath else { throw DockerClientError.socketUnavailable }
        do {
            let conn = try await ensureConnection(socketPath: socketPath)
            return try await exchange(connection: conn, path: path)
        } catch {
            resetConnection()
            let conn = try await ensureConnection(socketPath: socketPath)
            return try await exchange(connection: conn, path: path)
        }
    }

    private func ensureConnection(socketPath: String) async throws -> NWConnection {
        if let existing = connection, existing.state == .ready {
            return existing
        }
        resetConnection()

        let endpoint = NWEndpoint.unix(path: socketPath)
        let conn = NWConnection(to: endpoint, using: .tcp)
        let didFinish = ManagedAtomicFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if didFinish.setIfUnset() { cont.resume() }
                case .failed(let err):
                    if didFinish.setIfUnset() { cont.resume(throwing: err) }
                case .cancelled:
                    if didFinish.setIfUnset() { cont.resume(throwing: DockerClientError.connectionFailed) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        connection = conn
        return conn
    }

    func disconnect() {
        resetConnection()
    }

    private func resetConnection() {
        connection?.cancel()
        connection = nil
        rxBuffer.removeAll(keepingCapacity: true)
    }

    private func exchange(connection conn: NWConnection, path: String) async throws -> Data {
        try await send(conn, data: Self.httpRequest(path: path))
        return try await receiveResponse(conn)
    }

    private static func httpRequest(path: String) -> Data {
        let req = "GET \(path) HTTP/1.1\r\nHost: docker\r\nAccept: application/json\r\n\r\n"
        return Data(req.utf8)
    }

    private func send(_ conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func receiveChunk(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(returning: Data()); return }
                cont.resume(returning: Data())
            }
        }
    }

    private func receiveResponse(_ conn: NWConnection) async throws -> Data {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])

        while rxBuffer.range(of: sep) == nil {
            let chunk = try await receiveChunk(conn)
            if chunk.isEmpty { throw DockerClientError.invalidResponse }
            rxBuffer.append(chunk)
        }
        let sepRange = rxBuffer.range(of: sep)!
        let headerData = rxBuffer.subdata(in: 0..<sepRange.lowerBound)
        rxBuffer.removeSubrange(0..<sepRange.upperBound)

        let (status, contentLength, chunked) = try Self.parseHeaders(headerData)

        let body: Data
        if let len = contentLength {
            while rxBuffer.count < len {
                let chunk = try await receiveChunk(conn)
                if chunk.isEmpty { throw DockerClientError.invalidResponse }
                rxBuffer.append(chunk)
            }
            body = rxBuffer.subdata(in: 0..<len)
            rxBuffer.removeSubrange(0..<len)
        } else if chunked {
            body = try await readChunked(conn)
        } else {
            throw DockerClientError.invalidResponse
        }

        guard (200..<300).contains(status) else { throw DockerClientError.httpStatus(status) }
        return body
    }

    private func readChunked(_ conn: NWConnection) async throws -> Data {
        var out = Data()
        let crlf = Data([0x0D, 0x0A])

        while true {
            while rxBuffer.range(of: crlf) == nil {
                let chunk = try await receiveChunk(conn)
                if chunk.isEmpty { throw DockerClientError.invalidResponse }
                rxBuffer.append(chunk)
            }
            let lineRange = rxBuffer.range(of: crlf)!
            let sizeLineData = rxBuffer.subdata(in: 0..<lineRange.lowerBound)
            rxBuffer.removeSubrange(0..<lineRange.upperBound)

            guard let sizeLine = String(data: sizeLineData, encoding: .ascii) else {
                throw DockerClientError.invalidResponse
            }
            let hex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw DockerClientError.invalidResponse
            }

            if size == 0 {
                while rxBuffer.count < 2 {
                    let chunk = try await receiveChunk(conn)
                    if chunk.isEmpty { break }
                    rxBuffer.append(chunk)
                }
                if rxBuffer.count >= 2, rxBuffer.subdata(in: 0..<2) == crlf {
                    rxBuffer.removeSubrange(0..<2)
                }
                return out
            }

            let needed = size + 2
            while rxBuffer.count < needed {
                let chunk = try await receiveChunk(conn)
                if chunk.isEmpty { throw DockerClientError.invalidResponse }
                rxBuffer.append(chunk)
            }
            out.append(rxBuffer.subdata(in: 0..<size))
            rxBuffer.removeSubrange(0..<needed)
        }
    }

    private static func parseHeaders(_ headerData: Data) throws -> (status: Int, contentLength: Int?, chunked: Bool) {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw DockerClientError.invalidResponse
        }
        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else { throw DockerClientError.invalidResponse }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw DockerClientError.invalidResponse
        }

        var contentLength: Int?
        var chunked = false
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value)
            } else if lower.hasPrefix("transfer-encoding:"), lower.contains("chunked") {
                chunked = true
            }
        }
        return (status, contentLength, chunked)
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false
    func setIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flagged { return false }
        flagged = true
        return true
    }
}
