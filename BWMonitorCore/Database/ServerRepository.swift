import Foundation

public actor ServerRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppEnvironment.supportDirectory.appendingPathComponent("servers.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> [Server] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([Server].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ servers: [Server]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(servers).write(to: fileURL, options: .atomic)
    }
}
