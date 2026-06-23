import Foundation

public struct GlowKeyController: Sendable {
    private static let lowEndHybridThreshold = 25
    private static let hybridBlendWidth = 5

    private let registry: DisplayRegistry
    private let nativeBrightnessBackend: NativeBrightnessBackend
    private let ddcBrightnessBackend: AppleSiliconDDCBackend
    private let softwareBackend: GammaDimmingBackend

    public init(
        registry: DisplayRegistry = DisplayRegistry(),
        nativeBrightnessBackend: NativeBrightnessBackend = NativeBrightnessBackend(),
        ddcBrightnessBackend: AppleSiliconDDCBackend = AppleSiliconDDCBackend(),
        softwareBackend: GammaDimmingBackend = GammaDimmingBackend()
    ) {
        self.registry = registry
        self.nativeBrightnessBackend = nativeBrightnessBackend
        self.ddcBrightnessBackend = ddcBrightnessBackend
        self.softwareBackend = softwareBackend
    }

    public func displays() throws -> [Display] {
        try registry.onlineDisplays()
    }

    public func controlStatuses() throws -> [DisplayControlStatus] {
        try displays().map { display in
            if display.isBuiltin {
                return DisplayControlStatus(
                    display: display,
                    quality: .realBrightness,
                    userMessage: "Ready."
                )
            }

            if realBrightnessBackend(for: display) != nil {
                return DisplayControlStatus(
                    display: display,
                    quality: .realBrightness,
                    userMessage: "Ready."
                )
            }

            if softwareBackend.canControl(display) {
                return DisplayControlStatus(
                    display: display,
                    quality: .softwareDimming,
                    userMessage: "Ready with smooth brightness fallback.",
                    suggestion: "A direct USB-C or DisplayPort cable can improve brightness range."
                )
            }

            return DisplayControlStatus(
                display: display,
                quality: .limitedControl,
                userMessage: "This display is visible but cannot be adjusted right now.",
                suggestion: "Reconnect the display or try a direct display cable."
            )
        }
    }

    public func setBrightness(_ brightness: Brightness, selector: DisplaySelector) throws {
        _ = try applyBrightness(brightness, selector: selector)
    }

    public func currentBrightness(for display: Display) -> Int? {
        if let brightness = nativeBrightnessBackend.currentBrightness(for: display) {
            return brightness
        }

        if let brightness = ddcBrightnessBackend.currentBrightness(for: display) {
            return brightness
        }

        return nil
    }

    public func applyBrightness(_ brightness: Brightness, selector: DisplaySelector) throws -> BrightnessApplication {
        let selectedDisplays = try selectDisplays(selector)
        guard !selectedDisplays.isEmpty else {
            throw GlowKeyError.noControllableDisplays
        }

        let builtinDisplays = selectedDisplays.filter(\.isBuiltin)
        let externalDisplays = selectedDisplays.filter { !$0.isBuiltin }

        for display in builtinDisplays {
            try nativeBrightnessBackend.setBrightness(brightness, for: display)
        }

        guard !externalDisplays.isEmpty else {
            return builtinDisplays.isEmpty
                ? BrightnessApplication(method: .normalBrightness)
                : BrightnessApplication(method: .realBrightness)
        }

        let canUseNativeBrightness = externalDisplays.allSatisfy(nativeBrightnessBackend.canControl)
        if canUseNativeBrightness {
            do {
                for display in externalDisplays {
                    try nativeBrightnessBackend.setBrightness(brightness, for: display)
                }
                return BrightnessApplication(method: .realBrightness)
            } catch {
                return BrightnessApplication(method: .softwareDimming)
            }
        }

        let canUseDDCBrightness = externalDisplays.allSatisfy(ddcBrightnessBackend.canControl)
        if canUseDDCBrightness {
            do {
                var overlayBrightness: Int?
                let hardwareBrightness = max(brightness.percentage, Self.lowEndHybridThreshold)
                let hardwareTarget = brightness.percentage < Self.lowEndHybridThreshold
                    ? Brightness(hardwareBrightness)
                    : brightness

                if brightness.percentage < Self.lowEndHybridThreshold {
                    overlayBrightness = Self.overlayBrightness(
                        requested: brightness.percentage,
                        hardwareBrightness: Self.lowEndHybridThreshold
                    )
                } else if brightness.percentage < Self.lowEndHybridThreshold + Self.hybridBlendWidth {
                    overlayBrightness = Self.thresholdBlendOverlayBrightness(requested: brightness.percentage)
                }

                for display in externalDisplays {
                    try ddcBrightnessBackend.setBrightness(hardwareTarget, for: display)
                    if let actual = ddcBrightnessBackend.currentBrightness(for: display),
                       actual > brightness.percentage,
                       brightness.percentage >= Self.lowEndHybridThreshold,
                       brightness.percentage < 100
                    {
                        overlayBrightness = Self.overlayBrightness(requested: brightness.percentage, hardwareBrightness: actual)
                    }
                }
                return BrightnessApplication(method: .realBrightness, overlayBrightness: overlayBrightness)
            } catch {
                return BrightnessApplication(method: .softwareDimming)
            }
        }

        return BrightnessApplication(method: .softwareDimming)
    }

    public func reset(selector: DisplaySelector) throws {
        let selectedDisplays = try selectDisplays(selector)
        guard !selectedDisplays.isEmpty else {
            throw GlowKeyError.noControllableDisplays
        }

        for display in selectedDisplays {
            try? nativeBrightnessBackend.reset(display)
            try? ddcBrightnessBackend.reset(display)
            try softwareBackend.reset(display)
        }
    }

    private func realBrightnessBackend(for display: Display) -> (any BrightnessBackend)? {
        if nativeBrightnessBackend.canControl(display) {
            return nativeBrightnessBackend
        }

        if ddcBrightnessBackend.canControl(display) {
            return ddcBrightnessBackend
        }

        return nil
    }

    private static func overlayBrightness(requested: Int, hardwareBrightness: Int) -> Int {
        guard hardwareBrightness > 0 else {
            return requested
        }

        let ratio = Double(requested) / Double(hardwareBrightness)
        return min(99, max(0, Int((ratio * 100).rounded())))
    }

    private static func thresholdBlendOverlayBrightness(requested: Int) -> Int? {
        let distanceAboveThreshold = requested - lowEndHybridThreshold
        let remainingBlend = hybridBlendWidth - distanceAboveThreshold
        guard remainingBlend > 0 else {
            return nil
        }

        let maxDimAtThreshold = 100 - overlayBrightness(
            requested: lowEndHybridThreshold - 1,
            hardwareBrightness: lowEndHybridThreshold
        )
        let dim = Double(maxDimAtThreshold) * (Double(remainingBlend) / Double(hybridBlendWidth))
        return min(99, max(0, Int((100 - dim).rounded())))
    }

    private func selectDisplays(_ selector: DisplaySelector) throws -> [Display] {
        let allDisplays = try displays()

        switch selector {
        case .all:
            return allDisplays
        case .external:
            return allDisplays.filter { !$0.isBuiltin }
        case let .id(id):
            guard let display = allDisplays.first(where: { $0.id == id }) else {
                throw GlowKeyError.displayNotFound(String(id))
            }
            return [display]
        case let .uuid(uuid):
            guard let display = allDisplays.first(where: { $0.uuid.localizedCaseInsensitiveContains(uuid) }) else {
                throw GlowKeyError.displayNotFound(uuid)
            }
            return [display]
        }
    }
}

public struct BrightnessApplication: Equatable, Sendable {
    public let method: RuntimeControlMethod
    public let overlayBrightness: Int?

    public init(method: RuntimeControlMethod, overlayBrightness: Int? = nil) {
        self.method = method
        self.overlayBrightness = overlayBrightness
    }
}

public enum DisplaySelector: Equatable, Sendable {
    case all
    case external
    case id(UInt32)
    case uuid(String)

    public init(_ rawValue: String) {
        switch rawValue.lowercased() {
        case "all":
            self = .all
        case "external", "externals":
            self = .external
        default:
            if let id = UInt32(rawValue) {
                self = .id(id)
            } else {
                self = .uuid(rawValue)
            }
        }
    }
}
