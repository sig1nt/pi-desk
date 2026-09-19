import Foundation

/// SwiftPM's generated accessor expects resources beside the executable bundle.
/// Packaged apps use the conventional Contents/Resources location instead.
enum PiResources {
    static var bundle: Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.url(forResource: "PiDesk_PiDesk", withExtension: "bundle")
                .flatMap(Bundle.init(url:)) ?? Bundle.main
        }
        return Bundle.module
    }
}
