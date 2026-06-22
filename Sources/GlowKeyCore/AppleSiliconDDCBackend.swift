import CGlowKeyDDC
import CoreFoundation
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

public struct AppleSiliconDDCServiceProbe: Equatable, Sendable {
    public let index: Int
    public let location: String
    public let ioDisplayLocation: String
    public let edidUUID: String
    public let manufacturerID: String
    public let productName: String
    public let serialNumber: String
    public let upstreamTransport: String
    public let downstreamTransport: String
    public let brightness: Int?
    public let maxBrightness: Int?

    public var canReadBrightness: Bool {
        brightness != nil && maxBrightness != nil
    }
}

public struct AppleSiliconDDCBackend: BrightnessBackend {
    public let name = "Real brightness"
    private let registry: DisplayRegistry
    private let profileCacheStore: BackendProfileCacheStore

    private static let ddcAddress: UInt8 = 0x37
    private static let dataAddress: UInt8 = 0x51
    private static let brightnessVCP: UInt8 = 0x10

    public init(
        registry: DisplayRegistry = DisplayRegistry(),
        profileCacheStore: BackendProfileCacheStore = BackendProfileCacheStore()
    ) {
        self.registry = registry
        self.profileCacheStore = profileCacheStore
    }

    public func canControl(_ display: Display) -> Bool {
        guard !display.isBuiltin else {
            return false
        }

        if matchedCachedService(for: display) != nil {
            return true
        }

        guard let service = matchedService(for: display) else {
            return false
        }

        guard Self.readBrightness(service: service.service) != nil else {
            return false
        }

        cache(service: service, for: display)
        return true
    }

    public func setBrightness(_ brightness: Brightness, for display: Display) throws {
        guard !display.isBuiltin, let service = matchedCachedService(for: display) ?? matchedService(for: display) else {
            throw GlowKeyError.hardwareBrightnessUnavailable
        }

        guard Self.writeBrightness(service: service.service, percentage: brightness.percentage) else {
            profileCacheStore.removeProfile(for: Self.displayCacheKey(display))
            throw GlowKeyError.hardwareBrightnessUnavailable
        }

        cache(service: service, for: display)
    }

    public func reset(_ display: Display) throws {}

    public func currentBrightness(for display: Display) -> Int? {
        guard !display.isBuiltin, let service = matchedCachedService(for: display) ?? matchedService(for: display) else {
            return nil
        }

        guard let values = Self.readBrightness(service: service.service), values.max > 0 else {
            return nil
        }

        return min(100, max(0, Int((Double(values.current) / Double(values.max) * 100).rounded())))
    }

    private func matchedService(for display: Display) -> ServiceCandidate? {
        let services = Self.externalServices()
        guard !services.isEmpty else {
            return nil
        }

        if externalDisplayCount() == 1, services.count == 1 {
            return services[0]
        }

        let matches = services
            .map { service in (service: service, score: Self.matchScore(display: display, service: service)) }
            .filter { $0.score >= 8 }
            .sorted { lhs, rhs in lhs.score > rhs.score }

        guard let best = matches.first else {
            return nil
        }

        if matches.dropFirst().contains(where: { $0.score == best.score }) {
            return nil
        }

        return best.service
    }

    private func matchedCachedService(for display: Display) -> ServiceCandidate? {
        guard let profile = profileCacheStore.profile(for: Self.displayCacheKey(display)),
              profile.method == .realBrightness
        else {
            return nil
        }

        return Self.externalServices().first { service in
            service.cacheFingerprint == profile.serviceFingerprint
        }
    }

    private func cache(service: ServiceCandidate, for display: Display) {
        profileCacheStore.save(BackendDisplayProfile(
            displayKey: Self.displayCacheKey(display),
            method: .realBrightness,
            serviceFingerprint: service.cacheFingerprint
        ))
    }

    private func externalDisplayCount() -> Int {
        (try? registry.onlineDisplays().filter { !$0.isBuiltin }.count) ?? 0
    }

    private static func matchScore(display: Display, service: ServiceCandidate) -> Int {
        var score = 0

        if !service.productName.isEmpty,
           service.productName.normalizedDisplayName == display.name.normalizedDisplayName
        {
            score += 8
        }

        if service.metadata.serialNumberNumeric != 0,
           service.metadata.serialNumberNumeric == Int64(display.serialNumber)
        {
            score += 6
        }

        if !service.edidUUID.isEmpty {
            let edid = service.edidUUID.uppercased()
            let vendorHex = String(format: "%04X", UInt16(display.vendorID & 0xffff))
            let modelLEHex = String(
                format: "%02X%02X",
                UInt8(display.modelID & 0xff),
                UInt8((display.modelID >> 8) & 0xff)
            )

            if edid.hasPrefix(vendorHex) {
                score += 2
            }

            if edid.dropFirst(4).prefix(4) == Substring(modelLEHex) {
                score += 2
            }
        }

        return score
    }

    private static func displayCacheKey(_ display: Display) -> String {
        [
            String(display.vendorID),
            String(display.modelID),
            String(display.serialNumber),
            display.name.normalizedDisplayName
        ].joined(separator: "-")
    }

    public static func probeServices() -> [AppleSiliconDDCServiceProbe] {
        externalServices().enumerated().map { index, service in
            let values = readBrightness(service: service.service)
            return AppleSiliconDDCServiceProbe(
                index: index + 1,
                location: service.location,
                ioDisplayLocation: service.ioDisplayLocation,
                edidUUID: service.edidUUID,
                manufacturerID: service.manufacturerID,
                productName: service.productName,
                serialNumber: service.serialNumber,
                upstreamTransport: service.upstreamTransport,
                downstreamTransport: service.downstreamTransport,
                brightness: values?.current,
                maxBrightness: values?.max
            )
        }
    }

    public static func displayNameOverrides(for displays: [Display]) -> [CGDirectDisplayID: String] {
        let services = externalServices()
        guard !services.isEmpty else {
            return [:]
        }

        var overrides: [CGDirectDisplayID: String] = [:]
        for display in displays where !display.isBuiltin {
            let matches = services
                .map { service in (service: service, score: matchScore(display: display, service: service)) }
                .filter { $0.score >= 4 }
                .sorted { $0.score > $1.score }

            guard let best = matches.first,
                  !best.service.productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }

            overrides[display.id] = readableDisplayName(for: best.service)
        }

        return overrides
    }

    private static func readableDisplayName(for service: ServiceCandidate) -> String {
        let manufacturer = service.manufacturerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let product = service.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !product.isEmpty else {
            return manufacturer
        }

        if manufacturer.isEmpty || product.normalizedDisplayName.contains(manufacturer.normalizedDisplayName) {
            return product
        }

        return "\(manufacturer) \(product)"
    }

    private static func externalServices() -> [ServiceCandidate] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else {
            return []
        }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [ServiceCandidate] = []
        var currentMetadata = ServiceMetadata()

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            let name = registryName(for: entry)
            if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
                currentMetadata = metadata(from: entry)
                continue
            }

            guard name == "DCPAVServiceProxy" else {
                continue
            }

            let location = stringProperty("Location", on: entry)
            guard location == "External" else {
                continue
            }

            guard let unmanagedService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else {
                continue
            }

            let service = unmanagedService.takeRetainedValue()
            candidates.append(ServiceCandidate(
                service: service,
                location: location ?? "External",
                ioDisplayLocation: currentMetadata.ioDisplayLocation,
                edidUUID: currentMetadata.edidUUID,
                metadata: currentMetadata
            ))
        }

        return candidates
    }

    private static func readBrightness(service: IOAVService) -> (current: Int, max: Int)? {
        var send = [brightnessVCP]
        var reply = [UInt8](repeating: 0, count: 11)

        guard performDDCCommunication(service: service, send: &send, reply: &reply) else {
            return nil
        }

        let max = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        guard max > 0 else {
            return nil
        }

        return (current, max)
    }

    private static func writeBrightness(service: IOAVService, percentage: Int) -> Bool {
        let clamped = UInt16(max(0, min(100, percentage)))
        var send = [brightnessVCP, UInt8(clamped >> 8), UInt8(clamped & 0xff)]
        var reply: [UInt8] = []
        return performDDCCommunication(service: service, send: &send, reply: &reply)
    }

    private static func performDDCCommunication(service: IOAVService, send: inout [UInt8], reply: inout [UInt8]) -> Bool {
        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        packet[packet.count - 1] = checksum(
            seed: send.count == 1 ? ddcAddress << 1 : ddcAddress << 1 ^ dataAddress,
            data: packet,
            end: packet.count - 2
        )

        for _ in 0..<5 {
            var writeOK = false
            for _ in 0..<2 {
                usleep(10_000)
                writeOK = IOAVServiceWriteI2C(
                    service,
                    UInt32(ddcAddress),
                    UInt32(dataAddress),
                    &packet,
                    UInt32(packet.count)
                ) == kIOReturnSuccess
            }

            guard writeOK else {
                usleep(20_000)
                continue
            }

            if reply.isEmpty {
                return true
            }

            usleep(50_000)
            let readOK = IOAVServiceReadI2C(
                service,
                UInt32(ddcAddress),
                UInt32(dataAddress),
                &reply,
                UInt32(reply.count)
            ) == kIOReturnSuccess

            if readOK && checksum(seed: 0x50, data: reply, end: reply.count - 2) == reply[reply.count - 1] {
                return true
            }

            usleep(20_000)
        }

        return false
    }

    private static func checksum(seed: UInt8, data: [UInt8], end: Int) -> UInt8 {
        guard end >= 0 else {
            return seed
        }

        var result = seed
        for index in 0...end {
            result ^= data[index]
        }
        return result
    }

    private static func metadata(from entry: io_registry_entry_t) -> ServiceMetadata {
        let displayAttributes = dictionaryProperty("DisplayAttributes", on: entry)
        let productAttributes = displayAttributes?["ProductAttributes"] as? NSDictionary
        let transport = dictionaryProperty("Transport", on: entry)

        return ServiceMetadata(
            ioDisplayLocation: registryPath(for: entry),
            edidUUID: stringProperty("EDID UUID", on: entry) ?? "",
            manufacturerID: productAttributes?["ManufacturerID"] as? String ?? "",
            productName: productAttributes?["ProductName"] as? String ?? "",
            serialNumberNumeric: productAttributes?["SerialNumber"] as? Int64 ?? 0,
            serialNumber: productAttributes?["AlphanumericSerialNumber"] as? String ?? "",
            upstreamTransport: transport?["Upstream"] as? String ?? "",
            downstreamTransport: transport?["Downstream"] as? String ?? ""
        )
    }

    private static func registryName(for entry: io_registry_entry_t) -> String {
        let capacity = MemoryLayout<io_name_t>.size
        let name = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { name.deallocate() }

        guard IORegistryEntryGetName(entry, name) == KERN_SUCCESS else {
            return ""
        }

        return String(cString: name)
    }

    private static func registryPath(for entry: io_registry_entry_t) -> String {
        let capacity = MemoryLayout<io_string_t>.size
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer { path.deallocate() }

        guard IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS else {
            return ""
        }

        return String(cString: path)
    }

    private static func stringProperty(_ key: String, on entry: io_registry_entry_t) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func dictionaryProperty(_ key: String, on entry: io_registry_entry_t) -> NSDictionary? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSDictionary
    }
}

private struct ServiceMetadata {
    var ioDisplayLocation = ""
    var edidUUID = ""
    var manufacturerID = ""
    var productName = ""
    var serialNumberNumeric: Int64 = 0
    var serialNumber = ""
    var upstreamTransport = ""
    var downstreamTransport = ""
}

private struct ServiceCandidate {
    let service: IOAVService
    let location: String
    let ioDisplayLocation: String
    let edidUUID: String
    let metadata: ServiceMetadata

    var manufacturerID: String { metadata.manufacturerID }
    var productName: String { metadata.productName }
    var serialNumber: String { metadata.serialNumber }
    var upstreamTransport: String { metadata.upstreamTransport }
    var downstreamTransport: String { metadata.downstreamTransport }
    var cacheFingerprint: String {
        [
            edidUUID,
            manufacturerID.normalizedDisplayName,
            productName.normalizedDisplayName,
            String(metadata.serialNumberNumeric),
            serialNumber.normalizedDisplayName,
            upstreamTransport.normalizedDisplayName,
            downstreamTransport.normalizedDisplayName
        ].joined(separator: "|")
    }
}

private extension String {
    var normalizedDisplayName: String {
        lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}
