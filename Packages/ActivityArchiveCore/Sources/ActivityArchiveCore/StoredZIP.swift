import CryptoKit
import Foundation

struct StoredZIPPayload {
  var path: String
  var source: ActivityPackagePayloadSource
  var byteLength: UInt64
  var crc32: UInt32
  var sha256: String
}

enum StoredZIPWriter {
  static func write(payloads: [StoredZIPPayload], to destination: URL) throws {
    let manager = FileManager.default
    let parent = destination.deletingLastPathComponent()
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let temporary = parent.appending(
      path: ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
    )
    var removeTemporary = true
    defer { if removeTemporary { try? manager.removeItem(at: temporary) } }

    guard manager.createFile(atPath: temporary.path, contents: nil) else {
      throw ActivityPackageError.invalidArchive("Could not create the destination")
    }
    let output = try FileHandle(forWritingTo: temporary)
    defer { try? output.close() }
    var offset: UInt64 = 0
    var records: [StoredZIPCentralRecord] = []

    for payload in payloads.sorted(by: { $0.path < $1.path }) {
      try Task.checkCancellation()
      guard payload.byteLength <= UInt64(UInt32.max),
        offset <= UInt64(UInt32.max),
        let name = payload.path.data(using: .utf8),
        name.count <= Int(UInt16.max)
      else {
        throw ActivityPackageError.invalidArchive("ZIP32 limit exceeded")
      }
      let header = localHeader(
        name: name,
        crc32: payload.crc32,
        byteLength: UInt32(payload.byteLength)
      )
      try output.write(contentsOf: header)
      offset += UInt64(header.count)
      try write(
        source: payload.source,
        expectedSize: payload.byteLength,
        expectedCRC32: payload.crc32,
        expectedSHA256: payload.sha256,
        to: output
      )
      records.append(
        StoredZIPCentralRecord(
          name: name,
          crc32: payload.crc32,
          byteLength: UInt32(payload.byteLength),
          localHeaderOffset: UInt32(offset - UInt64(header.count))
        )
      )
      offset += payload.byteLength
    }

    guard records.count <= Int(UInt16.max), offset <= UInt64(UInt32.max) else {
      throw ActivityPackageError.invalidArchive("ZIP32 limit exceeded")
    }
    let centralOffset = UInt32(offset)
    var centralSize: UInt64 = 0
    for record in records {
      let data = record.data
      try output.write(contentsOf: data)
      centralSize += UInt64(data.count)
    }
    guard centralSize <= UInt64(UInt32.max) else {
      throw ActivityPackageError.invalidArchive("Central directory is too large")
    }
    var footer = Data()
    footer.appendLittleEndian(UInt32(0x0605_4b50))
    footer.appendLittleEndian(UInt16(0))
    footer.appendLittleEndian(UInt16(0))
    footer.appendLittleEndian(UInt16(records.count))
    footer.appendLittleEndian(UInt16(records.count))
    footer.appendLittleEndian(UInt32(centralSize))
    footer.appendLittleEndian(centralOffset)
    footer.appendLittleEndian(UInt16(0))
    try output.write(contentsOf: footer)
    try output.synchronize()
    try output.close()

    if manager.fileExists(atPath: destination.path) {
      _ = try manager.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try manager.moveItem(at: temporary, to: destination)
    }
    removeTemporary = false
  }

  private static func localHeader(name: Data, crc32: UInt32, byteLength: UInt32) -> Data {
    var data = Data()
    data.appendLittleEndian(UInt32(0x0403_4b50))
    data.appendLittleEndian(UInt16(20))
    data.appendLittleEndian(UInt16(0x0800))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(crc32)
    data.appendLittleEndian(byteLength)
    data.appendLittleEndian(byteLength)
    data.appendLittleEndian(UInt16(name.count))
    data.appendLittleEndian(UInt16(0))
    data.append(name)
    return data
  }

  private static func write(
    source: ActivityPackagePayloadSource,
    expectedSize: UInt64,
    expectedCRC32: UInt32,
    expectedSHA256: String,
    to output: FileHandle
  ) throws {
    var hasher = SHA256()
    var checksum = ActivityPackageCRC32()
    var written: UInt64 = 0

    func writeVerified(_ data: Data) throws {
      written += UInt64(data.count)
      guard written <= expectedSize else {
        throw ActivityPackageError.byteLengthMismatch("payload changed while packaging")
      }
      hasher.update(data: data)
      checksum.update(data)
      try output.write(contentsOf: data)
    }

    switch source {
    case .data(let data):
      try writeVerified(data)
    case .file(let url):
      let input = try FileHandle(forReadingFrom: url)
      defer { try? input.close() }
      while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
        try Task.checkCancellation()
        try writeVerified(chunk)
      }
    }
    guard written == expectedSize else {
      throw ActivityPackageError.byteLengthMismatch("payload changed while packaging")
    }
    let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard checksum.finalized == expectedCRC32,
      sha256 == expectedSHA256
    else {
      throw ActivityPackageError.checksumMismatch("payload changed while packaging")
    }
  }
}

private struct StoredZIPCentralRecord {
  var name: Data
  var crc32: UInt32
  var byteLength: UInt32
  var localHeaderOffset: UInt32

  var data: Data {
    var data = Data()
    data.appendLittleEndian(UInt32(0x0201_4b50))
    data.appendLittleEndian(UInt16(20))
    data.appendLittleEndian(UInt16(20))
    data.appendLittleEndian(UInt16(0x0800))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(crc32)
    data.appendLittleEndian(byteLength)
    data.appendLittleEndian(byteLength)
    data.appendLittleEndian(UInt16(name.count))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt16(0))
    data.appendLittleEndian(UInt32(0))
    data.appendLittleEndian(localHeaderOffset)
    data.append(name)
    return data
  }
}

struct StoredZIPEntry: Sendable {
  var path: String
  var byteLength: UInt64
  var crc32: UInt32
  var localHeaderOffset: UInt64
}

struct StoredZIPArchive {
  let url: URL
  let entries: [StoredZIPEntry]
  private let centralDirectoryOffset: UInt64
  private let entriesByPath: [String: StoredZIPEntry]

  init(url: URL, limits: ActivityPackageLimits) throws {
    try limits.validate()
    self.url = url
    let parsed = try Self.parse(url: url, limits: limits)
    entries = parsed.entries
    centralDirectoryOffset = parsed.centralDirectoryOffset
    entriesByPath = Dictionary(uniqueKeysWithValues: parsed.entries.map { ($0.path, $0) })
  }

  func entry(named path: String) -> StoredZIPEntry? {
    entriesByPath[path]
  }

  func data(for entry: StoredZIPEntry, maximumBytes: UInt64) throws -> Data {
    guard entry.byteLength <= maximumBytes,
      entry.byteLength <= UInt64(Int.max)
    else {
      throw ActivityPackageError.fileTooLarge(entry.path)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let dataOffset = try payloadOffset(for: entry, using: handle)
    try handle.seek(toOffset: dataOffset)
    let data = try readExactly(Int(entry.byteLength), from: handle, context: entry.path)
    var crc = ActivityPackageCRC32()
    crc.update(data)
    guard crc.finalized == entry.crc32 else {
      throw ActivityPackageError.checksumMismatch(entry.path)
    }
    return data
  }

  func sha256(for entry: StoredZIPEntry) throws -> String {
    try stream(entry: entry) { _ in }
  }

  func stream(entry: StoredZIPEntry, consume: (Data) throws -> Void) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let dataOffset = try payloadOffset(for: entry, using: handle)
    try handle.seek(toOffset: dataOffset)
    var remaining = entry.byteLength
    var hasher = SHA256()
    var crc = ActivityPackageCRC32()
    while remaining > 0 {
      try Task.checkCancellation()
      let count = Int(min(remaining, 64 * 1_024))
      guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
        throw ActivityPackageError.byteLengthMismatch(entry.path)
      }
      remaining -= UInt64(chunk.count)
      hasher.update(data: chunk)
      crc.update(chunk)
      try consume(chunk)
    }
    guard crc.finalized == entry.crc32 else {
      throw ActivityPackageError.checksumMismatch(entry.path)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func payloadOffset(for entry: StoredZIPEntry, using handle: FileHandle) throws -> UInt64 {
    try handle.seek(toOffset: entry.localHeaderOffset)
    let header = try readExactly(30, from: handle, context: entry.path)
    guard header.uint32(at: 0) == 0x0403_4b50,
      header.uint16(at: 6) == 0x0800,
      header.uint16(at: 8) == 0,
      header.uint32(at: 14) == entry.crc32,
      header.uint32(at: 18) == UInt32(entry.byteLength),
      header.uint32(at: 22) == UInt32(entry.byteLength)
    else {
      throw ActivityPackageError.invalidArchive("Invalid local header for \(entry.path)")
    }
    let nameLength = UInt64(header.uint16(at: 26))
    let extraLength = UInt64(header.uint16(at: 28))
    let name = try readExactly(Int(nameLength), from: handle, context: entry.path)
    guard String(data: name, encoding: .utf8) == entry.path else {
      throw ActivityPackageError.invalidArchive("Local path mismatch")
    }
    let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
    guard dataOffset <= centralDirectoryOffset,
      entry.byteLength <= centralDirectoryOffset - dataOffset
    else {
      throw ActivityPackageError.invalidArchive("Payload overlaps the central directory")
    }
    return dataOffset
  }

  private static func parse(
    url: URL,
    limits: ActivityPackageLimits
  ) throws -> (entries: [StoredZIPEntry], centralDirectoryOffset: UInt64) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let fileSize = try handle.seekToEnd()
    guard fileSize >= 22 else {
      throw ActivityPackageError.invalidArchive("Missing end record")
    }
    let tailLength = min(fileSize, 65_557)
    try handle.seek(toOffset: fileSize - tailLength)
    let tail = try readExactly(Int(tailLength), from: handle, context: "end record")
    guard let footerOffset = tail.lastIndex(ofLittleEndian: 0x0605_4b50) else {
      throw ActivityPackageError.invalidArchive("Missing end record")
    }
    guard footerOffset + 22 <= tail.count,
      tail.uint16(at: footerOffset + 4) == 0,
      tail.uint16(at: footerOffset + 6) == 0
    else {
      throw ActivityPackageError.unsupportedArchiveFeature("Multi-disk ZIP")
    }
    let entriesOnDisk = tail.uint16(at: footerOffset + 8)
    let entryCount = tail.uint16(at: footerOffset + 10)
    guard entriesOnDisk == entryCount,
      Int(entryCount) <= limits.maximumFileCount
    else {
      throw ActivityPackageError.invalidArchive("Invalid file count")
    }
    let centralSize = UInt64(tail.uint32(at: footerOffset + 12))
    let centralOffset = UInt64(tail.uint32(at: footerOffset + 16))
    let commentLength = Int(tail.uint16(at: footerOffset + 20))
    let footerAbsoluteOffset = fileSize - tailLength + UInt64(footerOffset)
    let (maximumCentralBytes, centralLimitOverflow) = UInt64(limits.maximumFileCount)
      .multipliedReportingOverflow(by: UInt64(46 + 1_024))
    guard footerOffset + 22 + commentLength == tail.count,
      commentLength == 0,
      centralOffset + centralSize == footerAbsoluteOffset,
      !centralLimitOverflow,
      centralSize <= maximumCentralBytes
    else {
      throw ActivityPackageError.invalidArchive("Invalid central directory")
    }

    try handle.seek(toOffset: centralOffset)
    let central = try readExactly(Int(centralSize), from: handle, context: "central directory")
    var cursor = 0
    var entries: [StoredZIPEntry] = []
    var seen = Set<String>()
    var totalBytes: UInt64 = 0

    while cursor < central.count {
      guard cursor + 46 <= central.count,
        central.uint32(at: cursor) == 0x0201_4b50
      else {
        throw ActivityPackageError.invalidArchive("Invalid central directory entry")
      }
      let flags = central.uint16(at: cursor + 8)
      let method = central.uint16(at: cursor + 10)
      let crc32 = central.uint32(at: cursor + 16)
      let compressedSize = central.uint32(at: cursor + 20)
      let uncompressedSize = central.uint32(at: cursor + 24)
      let nameLength = Int(central.uint16(at: cursor + 28))
      let extraLength = Int(central.uint16(at: cursor + 30))
      let commentLength = Int(central.uint16(at: cursor + 32))
      let disk = central.uint16(at: cursor + 34)
      let externalAttributes = central.uint32(at: cursor + 38)
      let localOffset = central.uint32(at: cursor + 42)
      let end = cursor + 46 + nameLength + extraLength + commentLength
      guard end <= central.count else {
        throw ActivityPackageError.invalidArchive("Truncated central directory entry")
      }
      guard flags == 0x0800 else {
        throw ActivityPackageError.unsupportedArchiveFeature(
          "Only unencrypted UTF-8 entries without data descriptors are accepted"
        )
      }
      guard method == 0, compressedSize == uncompressedSize else {
        throw ActivityPackageError.unsupportedArchiveFeature("Only stored entries are accepted")
      }
      guard disk == 0 else {
        throw ActivityPackageError.unsupportedArchiveFeature("Multi-disk ZIP")
      }
      guard UInt64(localOffset) + 30 <= centralOffset else {
        throw ActivityPackageError.invalidArchive("Invalid local header offset")
      }
      let unixMode = externalAttributes >> 16
      guard unixMode & 0o170000 != 0o120000 else {
        throw ActivityPackageError.unsupportedArchiveFeature("Symbolic links")
      }
      let nameData = central.subdata(in: cursor + 46..<cursor + 46 + nameLength)
      guard let rawPath = String(data: nameData, encoding: .utf8),
        !rawPath.hasSuffix("/")
      else {
        throw ActivityPackageError.invalidPath("Directory or non-UTF-8 entry")
      }
      let path = try ActivityPackagePath.validated(rawPath)
      let key = path.precomposedStringWithCanonicalMapping.lowercased()
      guard seen.insert(key).inserted else {
        throw ActivityPackageError.duplicatePath(path)
      }
      let byteLength = UInt64(uncompressedSize)
      guard byteLength <= limits.maximumFileBytes else {
        throw ActivityPackageError.fileTooLarge(path)
      }
      let (newTotal, overflow) = totalBytes.addingReportingOverflow(byteLength)
      guard !overflow, newTotal <= limits.maximumTotalBytes else {
        throw ActivityPackageError.archiveTooLarge
      }
      totalBytes = newTotal
      entries.append(
        StoredZIPEntry(
          path: path,
          byteLength: byteLength,
          crc32: crc32,
          localHeaderOffset: UInt64(localOffset)
        )
      )
      cursor = end
    }
    guard entries.count == Int(entryCount) else {
      throw ActivityPackageError.invalidArchive("File count does not match")
    }
    return (entries, centralOffset)
  }
}

private func readExactly(_ count: Int, from handle: FileHandle, context: String) throws -> Data {
  guard count >= 0 else {
    throw ActivityPackageError.invalidArchive("Truncated \(context)")
  }
  var result = Data()
  result.reserveCapacity(count)
  while result.count < count {
    let remaining = count - result.count
    guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
      throw ActivityPackageError.invalidArchive("Truncated \(context)")
    }
    result.append(chunk)
  }
  return result
}

extension Data {
  fileprivate mutating func appendLittleEndian(_ value: UInt16) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
  }

  fileprivate mutating func appendLittleEndian(_ value: UInt32) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value >> 16))
    append(UInt8(truncatingIfNeeded: value >> 24))
  }

  fileprivate func uint16(at offset: Int) -> UInt16 {
    UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  fileprivate func uint32(at offset: Int) -> UInt32 {
    UInt32(self[offset])
      | UInt32(self[offset + 1]) << 8
      | UInt32(self[offset + 2]) << 16
      | UInt32(self[offset + 3]) << 24
  }

  fileprivate func lastIndex(ofLittleEndian value: UInt32) -> Int? {
    guard count >= 4 else { return nil }
    for index in stride(from: count - 4, through: 0, by: -1) {
      if uint32(at: index) == value { return index }
    }
    return nil
  }
}
