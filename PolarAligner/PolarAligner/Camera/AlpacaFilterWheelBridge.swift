import Foundation
import PolarCore

/// Swift wrapper around the Rust AlpacaFilterWheelController.
final class AlpacaFilterWheelBridge {
    private let controller = AlpacaFilterWheelController()
    private(set) var info: AlpacaFilterWheelInfo?
    private(set) var isOpen = false

    func open(host: String, port: UInt32, deviceNumber: UInt32 = 0) throws {
        let wheelInfo = try controller.connect(host: host, port: port, deviceNumber: deviceNumber)
        info = wheelInfo
        isOpen = true
    }

    func close() throws {
        try controller.disconnect()
        isOpen = false
        info = nil
    }

    func getPosition() throws -> Int16 {
        try controller.getPosition()
    }

    func setPosition(_ position: Int16) throws {
        try controller.setPosition(position: position)
    }

    func getNames() throws -> [String] {
        try controller.getNames()
    }
}
