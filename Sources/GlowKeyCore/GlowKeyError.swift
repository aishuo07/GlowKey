import Foundation

public enum GlowKeyError: Error, LocalizedError {
    case displayNotFound(String)
    case hardwareBrightnessUnavailable
    case noControllableDisplays

    public var errorDescription: String? {
        switch self {
        case let .displayNotFound(selector):
            "No display matches '\(selector)'. Use `glowkey displays` to see available displays."
        case .hardwareBrightnessUnavailable:
            "Real hardware brightness is not available yet for this display."
        case .noControllableDisplays:
            "No controllable displays were found."
        }
    }
}
