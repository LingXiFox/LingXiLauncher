import Foundation
#if canImport(MacPlatform)
import MacPlatform
#elseif canImport(WindowsPlatform)
import WindowsPlatform
#endif

enum TestPlatform {
    static func install() {
        #if canImport(MacPlatform)
        MacPlatform.install()
        #elseif canImport(WindowsPlatform)
        WindowsPlatform.install()
        #endif
    }
}
