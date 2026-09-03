import CryptoKit
import Foundation

public enum ActivityPackageIdentity {
  /// A deterministic RFC 4122 version-5 UUID for one logical source observation.
  ///
  /// The same stable source activity ID always produces the same package ID. Revisions of that
  /// source reuse the package ID and increment `packageRevision`.
  public static func stablePackageID(for sourceActivityID: String) throws -> UUID {
    let identifier = sourceActivityID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else {
      throw ActivityPackageError.invalidManifest("Source activity ID is required")
    }

    var namespace = namespaceUUID.uuid
    var input = withUnsafeBytes(of: &namespace) { Data($0) }
    input.append(Data(identifier.utf8))
    var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }

  private static let namespaceUUID = UUID(uuidString: "E7CE67DE-B292-4F03-9204-F8D046C30A1C")!
}
