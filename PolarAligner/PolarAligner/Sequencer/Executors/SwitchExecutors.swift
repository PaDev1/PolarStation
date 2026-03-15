import Foundation

/// Executor for `set_switch` — sets a switch on/off or to a numeric value.
struct SetSwitchExecutor: InstructionExecutor {
    let instructionType = "set_switch"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let switchDev = context.deviceResolver.switchDev() else {
            throw ExecutorError.deviceNotAvailable("switch")
        }
        let switchId = Int32(instruction.params["switch_id"]?.intValue ?? 0)
        let name = switchDev.switchNames.indices.contains(Int(switchId))
            ? switchDev.switchNames[Int(switchId)] : "Switch \(switchId)"

        if let value = instruction.params["value"]?.doubleValue {
            context.status("Setting \(name) to \(String(format: "%.1f", value))")
            switchDev.setSwitchValue(id: switchId, value: value)
        } else {
            let state = instruction.params["state"]?.boolValue ?? true
            context.status("Setting \(name) \(state ? "ON" : "OFF")")
            switchDev.setSwitch(id: switchId, state: state)
        }
    }
}
