import Foundation

public enum RemoteFileKind: String, Codable, Sendable {
    case directory, file, symbolicLink, other
}

public struct RemoteFileEntry: Identifiable, Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var kind: RemoteFileKind
    public var size: UInt64
    public var modifiedAt: Date?
    public var id: String { path }

    public init(name: String, path: String, kind: RemoteFileKind, size: UInt64, modifiedAt: Date? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct RemoteDirectoryListing: Sendable {
    public var path: String
    public var entries: [RemoteFileEntry]

    public init(path: String, entries: [RemoteFileEntry]) {
        self.path = path
        self.entries = entries
    }
}

public enum RemoteFileError: LocalizedError {
    case invalidPath, invalidListing, regularFilesOnly, destinationExists, transferFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath: NSLocalizedString("The file path is invalid.", comment: "File error")
        case .invalidListing: NSLocalizedString("The server returned an unreadable directory listing.", comment: "File error")
        case .regularFilesOnly: NSLocalizedString("Select files to upload. Folder uploads are not supported yet.", comment: "File error")
        case .destinationExists: NSLocalizedString("A file with this name already exists. Rename the file before uploading.", comment: "File error")
        case let .transferFailed(message): message
        }
    }
}

/// NUL delimiters preserve names containing spaces, quotes, tabs and newlines.
/// Listing is read-only, and uploaded files are published without overwriting.
public enum RemoteFileCommands {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(directory: String, name: String) throws -> String {
        guard directory.hasPrefix("/"), !directory.contains("\0"),
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw RemoteFileError.invalidPath
        }
        let base = directory == "/" ? "" : "/" + directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base + "/" + name
    }

    public static func list(path: String) throws -> String {
        guard !path.contains("\0") else { throw RemoteFileError.invalidPath }
        let location = path.isEmpty ? "\"$HOME\"" : quote(path)
        return """
        set -e
        export LC_ALL=C
        cd -- \(location)
        printf '%s\\0' "$PWD"
        find . -mindepth 1 -maxdepth 1 -printf '%y\\0%s\\0%T@\\0%f\\0'
        """
    }

    public static func parseListing(_ output: String) throws -> RemoteDirectoryListing {
        let fields = output.components(separatedBy: "\0")
        guard let path = fields.first, path.hasPrefix("/"), fields.last == "",
              (fields.count - 2).isMultiple(of: 4) else { throw RemoteFileError.invalidListing }
        var entries: [RemoteFileEntry] = []
        for offset in stride(from: 1, to: fields.count - 1, by: 4) {
            guard let size = UInt64(fields[offset + 1]),
                  let timestamp = Double(fields[offset + 2]), timestamp.isFinite else {
                throw RemoteFileError.invalidListing
            }
            let kind: RemoteFileKind = switch fields[offset] {
            case "d": .directory
            case "f": .file
            case "l": .symbolicLink
            default: .other
            }
            let name = fields[offset + 3]
            entries.append(RemoteFileEntry(name: name, path: try join(directory: path, name: name),
                                           kind: kind, size: size, modifiedAt: Date(timeIntervalSince1970: timestamp)))
        }
        return RemoteDirectoryListing(path: path, entries: entries.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }
}

