import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.graphics

public enum BrightnessApplyMethod: String, Sendable {
    case realBrightness = "Real brightness"
    case softwareDimming = "Software dimming"
}

public struct BrightnessApplyResult: Equatable, Sendable {
    public let method: BrightnessApplyMethod
    public let hardwareDisplayCount: Int
    public let fallbackDisplayCount: Int

    public init(method: BrightnessApplyMethod, hardwareDisplayCount: Int, fallbackDisplayCount: Int) {
        self.method = method
        self.hardwareDisplayCount = hardwareDisplayCount
        self.fallbackDisplayCount = fallbackDisplayCount
    }
}

public struct NativeBrightnessBackend: BrightnessBackend {
    public let name = "Real brightness"
    private let registry: DisplayRegistry

    public init(registry: DisplayRegistry = DisplayRegistry()) {
        self.registry = registry
    }

    public func canControl(_ display: Display) -> Bool {
        if DisplayServicesBrightnessBackend.shared.canControl(display) {
            return true
        }

        for service in copyCandidateServices(for: display) {
            defer { IOObjectRelease(service) }
            if readableParameter(on: service) != nil {
                return true
            }
        }
        return false
    }

    public func setBrightness(_ brightness: Brightness, for display: Display) throws {
        if DisplayServicesBrightnessBackend.shared.setBrightness(brightness, for: display) {
            return
        }

        let value = Float(brightness.percentage) / 100
        for service in copyCandidateServices(for: display) {
            defer { IOObjectRelease(service) }

            for parameter in Self.parameterPriority {
                let result = IODisplaySetFloatParameter(
                    service,
                    IOOptionBits(0),
                    parameter as CFString,
                    value
                )

                if result == kIOReturnSuccess {
                    _ = IODisplayCommitParameters(service, IOOptionBits(0))
                    return
                }
            }
        }

        throw GlowKeyError.hardwareBrightnessUnavailable
    }

    public func reset(_ display: Display) throws {}

    private func copyCandidateServices(for display: Display) -> [io_service_t] {
        var services: [io_service_t] = []

        if let displayConnect = registry.copyDisplayConnectService(for: display) {
            services.append(displayConnect)
        }

        let framebuffer = HardwareProbe.framebufferService(for: display)
        if framebuffer != 0 {
            services.append(framebuffer)

            let displayService = IODisplayForFramebuffer(framebuffer, IOOptionBits(0))
            if displayService != 0 {
                services.append(displayService)
            }
        }

        return services
    }

    private func readableParameter(on service: io_service_t) -> String? {
        for parameter in Self.parameterPriority {
            var value: Float = 0
            let result = IODisplayGetFloatParameter(
                service,
                IOOptionBits(0),
                parameter as CFString,
                &value
            )

            if result == kIOReturnSuccess {
                return parameter
            }
        }

        return nil
    }

    private static let parameterPriority = [
        "brightness",
        "linear-brightness",
        "usable-linear-brightness"
    ]
}

private final class DisplayServicesBrightnessBackend: @unchecked Sendable {
    static let shared = DisplayServicesBrightnessBackend()

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightness: GetBrightness?
    private let setBrightnessFunction: SetBrightness?

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            getBrightness = nil
            setBrightnessFunction = nil
            return
        }

        if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
        } else {
            getBrightness = nil
        }

        if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightnessFunction = unsafeBitCast(symbol, to: SetBrightness.self)
        } else {
            setBrightnessFunction = nil
        }
    }

    func canControl(_ display: Display) -> Bool {
        guard display.isBuiltin, let getBrightness, setBrightnessFunction != nil else {
            return false
        }

        var value: Float = 0
        return getBrightness(display.id, &value) == 0
    }

    func setBrightness(_ brightness: Brightness, for display: Display) -> Bool {
        guard display.isBuiltin, let setBrightnessFunction else {
            return false
        }

        let value = Float(brightness.percentage) / 100
        return setBrightnessFunction(display.id, value) == 0
    }
}
