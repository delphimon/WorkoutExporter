import Foundation

/// A deterministic, streaming ZIP writer using the standard "stored" method.
/// Files are not compressed, avoiding private APIs and keeping package integrity auditable.
struct ZIPArchiveWriter: Sendable {
    func write(files: [(path: String, url: URL)], to destination: URL) throws {
        let temporaryURL = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        do {
            guard files.count <= Int(UInt16.max),
                  FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw WorkoutExporterError.zipCreationFailure("The archive exceeded ZIP32 limits or could not be created.")
            }
            try ExportUtilities.applyCompleteFileProtection(to: temporaryURL)
            let output = try FileHandle(forWritingTo: temporaryURL)
            defer { try? output.close() }
            var entries: [CentralDirectoryEntry] = []
            entries.reserveCapacity(files.count)
            var archiveOffset: UInt64 = 0

            for file in files.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                guard let name = file.path.data(using: .utf8),
                      name.count <= Int(UInt16.max),
                      archiveOffset <= UInt64(UInt32.max) else {
                    throw WorkoutExporterError.zipCreationFailure("A path or archive offset exceeded ZIP32 limits.")
                }
                let localOffset = UInt32(archiveOffset)
                var localHeader = Data()
                localHeader.appendUInt32(0x04034b50)
                localHeader.appendUInt16(20)
                localHeader.appendUInt16(0x0808) // UTF-8 plus trailing data descriptor.
                localHeader.appendUInt16(0)
                localHeader.appendUInt16(0)
                localHeader.appendUInt16(0)
                localHeader.appendUInt32(0)
                localHeader.appendUInt32(0)
                localHeader.appendUInt32(0)
                localHeader.appendUInt16(UInt16(name.count))
                localHeader.appendUInt16(0)
                localHeader.append(name)
                try output.write(contentsOf: localHeader)
                archiveOffset += UInt64(localHeader.count)

                let input = try FileHandle(forReadingFrom: file.url)
                var checksum = CRC32()
                var byteSize: UInt64 = 0
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    byteSize += UInt64(chunk.count)
                    guard byteSize <= UInt64(UInt32.max) else {
                        throw WorkoutExporterError.zipCreationFailure("\(file.path) exceeded ZIP32 limits.")
                    }
                    checksum.update(chunk)
                    try output.write(contentsOf: chunk)
                    archiveOffset += UInt64(chunk.count)
                }
                try input.close()

                var descriptor = Data()
                descriptor.appendUInt32(0x08074b50)
                descriptor.appendUInt32(checksum.finalized)
                descriptor.appendUInt32(UInt32(byteSize))
                descriptor.appendUInt32(UInt32(byteSize))
                try output.write(contentsOf: descriptor)
                archiveOffset += UInt64(descriptor.count)
                entries.append(
                    CentralDirectoryEntry(
                        name: name,
                        checksum: checksum.finalized,
                        byteSize: UInt32(byteSize),
                        localHeaderOffset: localOffset
                    )
                )
            }

            guard archiveOffset <= UInt64(UInt32.max) else {
                throw WorkoutExporterError.zipCreationFailure("The archive exceeded ZIP32 limits.")
            }
            let centralOffset = UInt32(archiveOffset)
            var centralSize: UInt64 = 0
            for entry in entries {
                try Task.checkCancellation()
                let record = entry.data
                try output.write(contentsOf: record)
                centralSize += UInt64(record.count)
            }
            guard centralSize <= UInt64(UInt32.max) else {
                throw WorkoutExporterError.zipCreationFailure("The central directory exceeded ZIP32 limits.")
            }
            var footer = Data()
            footer.appendUInt32(0x06054b50)
            footer.appendUInt16(0)
            footer.appendUInt16(0)
            footer.appendUInt16(UInt16(entries.count))
            footer.appendUInt16(UInt16(entries.count))
            footer.appendUInt32(UInt32(centralSize))
            footer.appendUInt32(centralOffset)
            footer.appendUInt16(0)
            try output.write(contentsOf: footer)
            try output.synchronize()
            try output.close()

            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            }
            try ExportUtilities.applyCompleteFileProtection(to: destination)
            shouldRemoveTemporary = false
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkoutExporterError {
            throw error
        } catch {
            throw WorkoutExporterError.zipCreationFailure(error.localizedDescription)
        }
    }
}

struct CRC32: Sendable {
    private static let table: [UInt32] = (0..<256).map { value in
        var entry = UInt32(value)
        for _ in 0..<8 {
            entry = entry & 1 == 1 ? 0xedb8_8320 ^ (entry >> 1) : entry >> 1
        }
        return entry
    }

    private var value: UInt32 = 0xffff_ffff

    mutating func update(_ data: Data) {
        for byte in data {
            value = Self.table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
        }
    }

    var finalized: UInt32 {
        value ^ 0xffff_ffff
    }

    static func checksum(_ data: Data) -> UInt32 {
        var checksum = CRC32()
        checksum.update(data)
        return checksum.finalized
    }
}

private struct CentralDirectoryEntry {
    let name: Data
    let checksum: UInt32
    let byteSize: UInt32
    let localHeaderOffset: UInt32

    var data: Data {
        var result = Data()
        result.appendUInt32(0x02014b50)
        result.appendUInt16(20)
        result.appendUInt16(20)
        result.appendUInt16(0x0808)
        result.appendUInt16(0)
        result.appendUInt16(0)
        result.appendUInt16(0)
        result.appendUInt32(checksum)
        result.appendUInt32(byteSize)
        result.appendUInt32(byteSize)
        result.appendUInt16(UInt16(name.count))
        result.appendUInt16(0)
        result.appendUInt16(0)
        result.appendUInt16(0)
        result.appendUInt16(0)
        result.appendUInt32(0)
        result.appendUInt32(localHeaderOffset)
        result.append(name)
        return result
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
