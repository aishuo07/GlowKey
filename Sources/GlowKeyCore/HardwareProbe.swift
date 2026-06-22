import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c

@_silgen_name("CGDisplayIOServicePort")
private func LSCGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

public struct DisplayHardwareProbe: Equatable, Sendable {
    public let display: Display
    public let framebufferService: UInt32
    public let displayConnectService: UInt32
    public let displayService: UInt32
    public let i2cBusCount: UInt32?
    public let parameters: [DisplayParameterProbe]

    public init(
        display: Display,
        framebufferService: UInt32,
        displayConnectService: UInt32,
        displayService: UInt32,
        i2cBusCount: UInt32?,
        parameters: [DisplayParameterProbe]
    ) {
        self.display = display
        self.framebufferService = framebufferService
        self.displayConnectService = displayConnectService
        self.displayService = displayService
        self.i2cBusCount = i2cBusCount
        self.parameters = parameters
    }
}

public struct DisplayParameterProbe: Equatable, Sendable {
    public let name: String
    public let floatValue: Float?
    public let integerValue: Int32?
    public let integerMin: Int32?
    public let integerMax: Int32?
    public let floatResult: Int32
    public let integerResult: Int32

    public init(
        name: String,
        floatValue: Float?,
        integerValue: Int32?,
        integerMin: Int32?,
        integerMax: Int32?,
        floatResult: Int32,
        integerResult: Int32
    ) {
        self.name = name
        self.floatValue = floatValue
        self.integerValue = integerValue
        self.integerMin = integerMin
        self.integerMax = integerMax
        self.floatResult = floatResult
        self.integerResult = integerResult
    }
}

public struct RawFramebufferProbe: Equatable, Sendable {
    public let service: UInt32
    public let name: String
    public let i2cBusCount: UInt32?
    public let i2cResult: Int32

    public init(service: UInt32, name: String, i2cBusCount: UInt32?, i2cResult: Int32) {
        self.service = service
        self.name = name
        self.i2cBusCount = i2cBusCount
        self.i2cResult = i2cResult
    }
}

public struct HardwareProbe: Sendable {
    private let registry: DisplayRegistry

    public init(registry: DisplayRegistry = DisplayRegistry()) {
        self.registry = registry
    }

    public func probeDisplays() throws -> [DisplayHardwareProbe] {
        try registry.onlineDisplays().map(probe)
    }

    public func probeRawFramebuffers() -> [RawFramebufferProbe] {
        let matching = IOServiceMatching("IOFramebuffer")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var probes: [RawFramebufferProbe] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var i2cBusCount: IOItemCount = 0
            let i2cResult = IOFBGetI2CInterfaceCount(service, &i2cBusCount)
            let name = (IORegistryEntryCreateCFProperty(service, "IOProviderClass" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String)
                ?? "IOFramebuffer"

            probes.append(RawFramebufferProbe(
                service: service,
                name: name,
                i2cBusCount: i2cResult == kIOReturnSuccess ? UInt32(i2cBusCount) : nil,
                i2cResult: i2cResult
            ))
        }

        return probes
    }

    public static func framebufferService(for display: Display) -> io_service_t {
        LSCGDisplayIOServicePort(display.id)
    }

    public func probe(_ display: Display) -> DisplayHardwareProbe {
        let framebuffer = Self.framebufferService(for: display)
        let displayService = framebuffer == 0 ? 0 : IODisplayForFramebuffer(framebuffer, IOOptionBits(0))
        let displayConnectService = registry.copyDisplayConnectService(for: display) ?? 0

        var i2cBusCount: IOItemCount = 0
        let i2cResult = framebuffer == 0 ? kIOReturnNoDevice : IOFBGetI2CInterfaceCount(framebuffer, &i2cBusCount)

        let serviceForParameters = firstNonZero(displayConnectService, displayService, framebuffer)
        let parameters = Self.parameterNames.map { parameterName in
            probeParameter(name: parameterName, service: serviceForParameters)
        }

        if displayConnectService != 0 {
            IOObjectRelease(displayConnectService)
        }

        return DisplayHardwareProbe(
            display: display,
            framebufferService: framebuffer,
            displayConnectService: displayConnectService,
            displayService: displayService,
            i2cBusCount: i2cResult == kIOReturnSuccess ? UInt32(i2cBusCount) : nil,
            parameters: parameters
        )
    }

    private func probeParameter(name: String, service: io_service_t) -> DisplayParameterProbe {
        guard service != 0 else {
            return DisplayParameterProbe(
                name: name,
                floatValue: nil,
                integerValue: nil,
                integerMin: nil,
                integerMax: nil,
                floatResult: kIOReturnNoDevice,
                integerResult: kIOReturnNoDevice
            )
        }

        let parameterName = name as CFString

        var floatValue: Float = 0
        let floatResult = IODisplayGetFloatParameter(
            service,
            IOOptionBits(0),
            parameterName,
            &floatValue
        )

        var integerValue: Int32 = 0
        var integerMin: Int32 = 0
        var integerMax: Int32 = 0
        let integerResult = IODisplayGetIntegerRangeParameter(
            service,
            IOOptionBits(0),
            parameterName,
            &integerValue,
            &integerMin,
            &integerMax
        )

        return DisplayParameterProbe(
            name: name,
            floatValue: floatResult == kIOReturnSuccess ? floatValue : nil,
            integerValue: integerResult == kIOReturnSuccess ? integerValue : nil,
            integerMin: integerResult == kIOReturnSuccess ? integerMin : nil,
            integerMax: integerResult == kIOReturnSuccess ? integerMax : nil,
            floatResult: floatResult,
            integerResult: integerResult
        )
    }

    private static let parameterNames = [
        "brightness",
        "linear-brightness",
        "usable-linear-brightness",
        "contrast",
        "speaker-volume"
    ]

    private func firstNonZero(_ services: io_service_t...) -> io_service_t {
        services.first { $0 != 0 } ?? 0
    }
}
