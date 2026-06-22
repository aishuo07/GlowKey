import Foundation

public struct HardwareBrightnessBackend: BrightnessBackend {
    public let name = "Real brightness"

    public init() {}

    public func canControl(_ display: Display) -> Bool {
        // DDC/CI probing will land here. Until then, do not claim hardware control.
        false
    }

    public func setBrightness(_ brightness: Brightness, for display: Display) throws {
        throw GlowKeyError.hardwareBrightnessUnavailable
    }

    public func reset(_ display: Display) throws {
        throw GlowKeyError.hardwareBrightnessUnavailable
    }
}
