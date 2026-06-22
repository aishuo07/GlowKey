import CoreGraphics
import Foundation
import IOKit.graphics

public enum DisplayRegistryError: Error, LocalizedError {
    case unableToReadDisplayList(CGError)

    public var errorDescription: String? {
        switch self {
        case let .unableToReadDisplayList(error):
            "Unable to read the macOS display list. CoreGraphics returned \(error.rawValue)."
        }
    }
}

public struct DisplayRegistry: Sendable {
    public init() {}

    public func onlineDisplays() throws -> [Display] {
        var displayCount: UInt32 = 0
        var error = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard error == .success else {
            throw DisplayRegistryError.unableToReadDisplayList(error)
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        error = CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        guard error == .success else {
            throw DisplayRegistryError.unableToReadDisplayList(error)
        }

        let displays = displayIDs
            .prefix(Int(displayCount))
            .map(makeDisplay)
            .sorted { lhs, rhs in
                if lhs.isBuiltin != rhs.isBuiltin {
                    return lhs.isBuiltin && !rhs.isBuiltin
                }
                return lhs.id < rhs.id
            }
        let nameOverrides = AppleSiliconDDCBackend.displayNameOverrides(for: displays)
        return displays.map { display in
            guard let name = nameOverrides[display.id], !name.isEmpty else {
                return display
            }
            return display.renamed(name)
        }
    }

    private func makeDisplay(id: CGDirectDisplayID) -> Display {
        Display(
            id: id,
            uuid: displayUUID(for: id),
            name: displayName(for: id),
            vendorID: CGDisplayVendorNumber(id),
            modelID: CGDisplayModelNumber(id),
            serialNumber: CGDisplaySerialNumber(id),
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isOnline: CGDisplayIsOnline(id) != 0,
            isActive: CGDisplayIsActive(id) != 0,
            bounds: CGDisplayBounds(id)
        )
    }

    private func displayUUID(for id: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        return "\(vendor)-\(model)-\(serial)-\(id)"
    }

    private func displayName(for id: CGDirectDisplayID) -> String {
        guard let service = copyDisplayConnectService(for: id) else {
            return fallbackName(for: id)
        }
        defer { IOObjectRelease(service) }

        let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as NSDictionary
        if let localizedNames = info[kDisplayProductName] as? [String: String] {
            if let englishName = localizedNames["en_US"], !englishName.isEmpty {
                return englishName
            }

            if let firstName = localizedNames.values.first, !firstName.isEmpty {
                return firstName
            }
        }

        return fallbackName(for: id)
    }

    private func fallbackName(for id: CGDirectDisplayID) -> String {
        CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "External Display \(id)"
    }

    public func copyDisplayConnectService(for display: Display) -> io_service_t? {
        copyDisplayConnectService(for: display.id)
    }

    public func copyDisplayConnectService(for id: CGDirectDisplayID) -> io_service_t? {
        let matching = IOServiceMatching("IODisplayConnect")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let targetVendor = CGDisplayVendorNumber(id)
        let targetProduct = CGDisplayModelNumber(id)
        let targetSerial = CGDisplaySerialNumber(id)

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as NSDictionary

            let vendor = (info[kDisplayVendorID] as? NSNumber)?.uint32Value
            let product = (info[kDisplayProductID] as? NSNumber)?.uint32Value
            let serial = (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0

            let matches = vendor == targetVendor
                && product == targetProduct
                && (targetSerial == 0 || serial == targetSerial)

            if matches {
                return service
            }

            IOObjectRelease(service)
        }

        return nil
    }
}
