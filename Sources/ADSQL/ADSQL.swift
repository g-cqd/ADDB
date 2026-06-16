@_exported import ADDBCore

/// Version and on-disk format metadata for the ADSQL package.
public enum ADSQLInfo {
    /// The ADSQL package release version.
    public static let version = "0.0.1"
    /// The on-disk file-format version this build reads and writes.
    public static let formatVersion = Format.formatVersion
}
