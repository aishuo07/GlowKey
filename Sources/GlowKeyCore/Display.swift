import CoreGraphics
import Foundation

public struct Display: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let uuid: String
    public let name: String
    public let vendorID: UInt32
    public let modelID: UInt32
    public let serialNumber: UInt32
    public let isBuiltin: Bool
    public let isOnline: Bool
    public let isActive: Bool
    public let bounds: CGRect

    public init(
        id: CGDirectDisplayID,
        uuid: String,
        name: String,
        vendorID: UInt32,
        modelID: UInt32,
        serialNumber: UInt32,
        isBuiltin: Bool,
        isOnline: Bool,
        isActive: Bool,
        bounds: CGRect
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
        self.isBuiltin = isBuiltin
        self.isOnline = isOnline
        self.isActive = isActive
        self.bounds = bounds
    }
}

public extension Display {
    var kindDescription: String {
        isBuiltin ? "Built-in" : "External"
    }

    var resolutionDescription: String {
        "\(Int(bounds.width))x\(Int(bounds.height))"
    }

    func renamed(_ name: String) -> Display {
        Display(
            id: id,
            uuid: uuid,
            name: name,
            vendorID: vendorID,
            modelID: modelID,
            serialNumber: serialNumber,
            isBuiltin: isBuiltin,
            isOnline: isOnline,
            isActive: isActive,
            bounds: bounds
        )
    }
}
