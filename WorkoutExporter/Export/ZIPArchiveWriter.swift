import Foundation

/// A deterministic, dependency-free ZIP writer using the standard "stored" method.
/// Files are not compressed, avoiding private APIs and keeping package integrity auditable.
struct ZIPArchiveWriter: Sendable {
    func write(files: [(path: String, data: Data)], to url: URL) throws {
        var archive = Data()
        var central = Data()
        var entries: UInt16 = 0

        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let name = file.path.data(using: .utf8),
                  name.count <= Int(UInt16.max),
                  file.data.count <= Int(UInt32.max) else {
                throw WorkoutExporterError.zipCreationFailure("A path or file exceeded ZIP32 limits.")
            }
            let offset = UInt32(archive.count)
            let checksum = CRC32.checksum(file.data)
            archive.appendUInt32(0x04034b50)
            archive.appendUInt16(20)
            archive.appendUInt16(0x0800)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(checksum)
            archive.appendUInt32(UInt32(file.data.count))
            archive.appendUInt32(UInt32(file.data.count))
            archive.appendUInt16(UInt16(name.count))
            archive.appendUInt16(0)
            archive.append(name)
            archive.append(file.data)

            central.appendUInt32(0x02014b50)
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0x0800)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(checksum)
            central.appendUInt32(UInt32(file.data.count))
            central.appendUInt32(UInt32(file.data.count))
            central.appendUInt16(UInt16(name.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(offset)
            central.append(name)
            entries &+= 1
        }

        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendUInt32(0x06054b50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(entries)
        archive.appendUInt16(entries)
        archive.appendUInt32(UInt32(central.count))
        archive.appendUInt32(centralOffset)
        archive.appendUInt16(0)
        do {
            try archive.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw WorkoutExporterError.zipCreationFailure(error.localizedDescription)
        }
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            var current = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                current = (current & 1) == 1 ? 0xedb8_8320 ^ (current >> 1) : current >> 1
            }
            crc = (crc >> 8) ^ current
        }
        return crc ^ 0xffff_ffff
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
