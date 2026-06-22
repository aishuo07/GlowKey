import Foundation

public struct Brightness: Equatable, Comparable, Sendable {
    public let percentage: Int

    public init(_ percentage: Int) {
        self.percentage = min(100, max(0, percentage))
    }

    public static func < (lhs: Brightness, rhs: Brightness) -> Bool {
        lhs.percentage < rhs.percentage
    }
}
