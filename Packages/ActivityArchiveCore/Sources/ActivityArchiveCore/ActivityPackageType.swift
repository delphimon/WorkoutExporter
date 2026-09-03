#if canImport(UniformTypeIdentifiers)
  import UniformTypeIdentifiers

  extension UTType {
    public static let activityPackage = UTType(
      exportedAs: "com.delphimon.activity-archive.package",
      conformingTo: .zip
    )
  }
#endif
