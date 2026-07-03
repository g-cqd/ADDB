@_spi(ADDBEngine) import ADDBExec
import ADSQLModel
@_exported import ADTestKit

/// The private-temp-directory helper is now the shared `ADTestKit.TemporaryDirectory`
/// (atomic `mkdtemp`, race-free recursive teardown). This alias keeps the dependent
/// ADSQL test files calling `TempDir()` / `.file(_:)` / `.cleanup()` untouched and
/// removes the hand-rolled `dirent`-walking teardown that leaked subdirectories.
public typealias TempDir = ADTestKit.TemporaryDirectory
