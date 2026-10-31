import LauncherCore

/// Installs the Apple platform implementations. Called once from the GUI and CLI entry points.
public enum MacPlatform {
    public static func install() {
        PlatformRuntime.install(fileLock: MacFileLocking())
        PlatformRuntime.install(
            host: MacHost(),
            system: MacSystemProfiler(),
            graphics: MacGraphicsProbe()
        )
        PlatformRuntime.install(credentials: MacKeychainCredentialStore())
    }
}
