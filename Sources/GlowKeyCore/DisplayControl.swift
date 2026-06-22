import Foundation

public enum ControlQuality: String, Sendable {
    case realBrightness = "Real brightness"
    case softwareDimming = "Software dimming"
    case limitedControl = "Limited control"
}

public struct DisplayControlStatus: Equatable, Sendable {
    public let display: Display
    public let quality: ControlQuality
    public let userMessage: String
    public let suggestion: String?

    public init(
        display: Display,
        quality: ControlQuality,
        userMessage: String,
        suggestion: String? = nil
    ) {
        self.display = display
        self.quality = quality
        self.userMessage = userMessage
        self.suggestion = suggestion
    }
}

public protocol BrightnessBackend: Sendable {
    var name: String { get }

    func canControl(_ display: Display) -> Bool
    func setBrightness(_ brightness: Brightness, for display: Display) throws
    func reset(_ display: Display) throws
}
