import Foundation

/// Binds a logical device role to a device type and optional connection hint.
///
/// Instructions reference roles (e.g., "imaging_camera") rather than concrete
/// devices, enabling sequences to be shared between users with different equipment.
struct DeviceRoleBinding: Codable, Identifiable, Hashable {
    let id: UUID
    var role: String
    var deviceType: String
    var displayName: String
    var connectionHint: DeviceConnectionHint?

    init(role: String, deviceType: String, displayName: String, connectionHint: DeviceConnectionHint? = nil) {
        self.id = UUID()
        self.role = role
        self.deviceType = deviceType
        self.displayName = displayName
        self.connectionHint = connectionHint
    }

    /// Standard device roles.
    static let defaultRoles: [DeviceRoleBinding] = [
        DeviceRoleBinding(role: "imaging_camera", deviceType: "camera", displayName: "Imaging Camera"),
        DeviceRoleBinding(role: "guide_camera", deviceType: "camera", displayName: "Guide Camera"),
        DeviceRoleBinding(role: "mount", deviceType: "mount", displayName: "Mount"),
        DeviceRoleBinding(role: "filter_wheel", deviceType: "filterwheel", displayName: "Filter Wheel"),
    ]
}

/// Optional hints for connecting to a specific device.
struct DeviceConnectionHint: Codable, Hashable {
    var `protocol`: String?
    var host: String?
    var port: UInt32?
    var deviceNumber: UInt32?
    var devicePath: String?
}
