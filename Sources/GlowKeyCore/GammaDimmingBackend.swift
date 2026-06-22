import CoreGraphics
import Foundation

public enum GammaDimmingError: Error, LocalizedError {
    case unableToSetGamma(CGError)
    case unableToResetGamma(CGError)

    public var errorDescription: String? {
        switch self {
        case let .unableToSetGamma(error):
            "Unable to apply software dimming. CoreGraphics returned \(error.rawValue)."
        case let .unableToResetGamma(error):
            "Unable to restore display color settings. CoreGraphics returned \(error.rawValue)."
        }
    }
}

public struct GammaDimmingBackend: BrightnessBackend {
    public let name = "Software dimming"
    private let sampleCount: UInt32

    public init(sampleCount: UInt32 = 256) {
        self.sampleCount = sampleCount
    }

    public func canControl(_ display: Display) -> Bool {
        display.isOnline && display.isActive
    }

    public func setBrightness(_ brightness: Brightness, for display: Display) throws {
        let scale = Float(brightness.percentage) / 100
        let table = makeTransferTable(scale: scale)

        let error = table.withUnsafeBufferPointer { red in
            table.withUnsafeBufferPointer { green in
                table.withUnsafeBufferPointer { blue in
                    CGSetDisplayTransferByTable(
                        display.id,
                        sampleCount,
                        red.baseAddress,
                        green.baseAddress,
                        blue.baseAddress
                    )
                }
            }
        }

        guard error == .success else {
            throw GammaDimmingError.unableToSetGamma(error)
        }
    }

    public func reset(_ display: Display) throws {
        CGDisplayRestoreColorSyncSettings()
    }

    private func makeTransferTable(scale: Float) -> [CGGammaValue] {
        (0..<sampleCount).map { index in
            let x = Float(index) / Float(sampleCount - 1)
            return CGGammaValue(x * scale)
        }
    }
}
