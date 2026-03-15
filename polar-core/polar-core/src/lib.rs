pub mod alpaca_common;
pub mod camera;
pub mod coordinates;
pub mod covercalibrator;
pub mod dome;
pub mod filterwheel;
pub mod focuser;
pub mod mount;
pub mod observingconditions;
pub mod plate_solver;
pub mod polar_error;
pub mod rotator;
pub mod safetymonitor;
pub mod switch;
pub mod time_utils;

use camera::AlpacaCameraController;
use camera::AlpacaCameraInfo;
use camera::AlpacaDeviceInfo;
use camera::CameraError;
use camera::discover_alpaca_cameras;
use coordinates::*;
use covercalibrator::AlpacaCoverCalibratorController;
use covercalibrator::AlpacaCoverCalibratorInfo;
use covercalibrator::CoverCalibratorError;
use covercalibrator::discover_alpaca_covercalibrators;
use dome::AlpacaDomeController;
use dome::AlpacaDomeInfo;
use dome::DomeError;
use dome::discover_alpaca_domes;
use filterwheel::AlpacaFilterWheelController;
use filterwheel::AlpacaFilterWheelInfo;
use filterwheel::FilterWheelError;
use filterwheel::discover_alpaca_filterwheels;
use focuser::AlpacaFocuserController;
use focuser::AlpacaFocuserInfo;
use focuser::FocuserError;
use focuser::discover_alpaca_focusers;
use mount::MountController;
use mount::MountError;
use mount::alpaca::discover_alpaca_mounts;
use observingconditions::AlpacaObservingConditionsController;
use observingconditions::AlpacaObservingConditionsInfo;
use observingconditions::ObservingConditionsError;
use observingconditions::discover_alpaca_observingconditions;
use plate_solver::*;
use polar_error::*;
use rotator::AlpacaRotatorController;
use rotator::AlpacaRotatorInfo;
use rotator::RotatorError;
use rotator::discover_alpaca_rotators;
use safetymonitor::AlpacaSafetyMonitorController;
use safetymonitor::AlpacaSafetyMonitorInfo;
use safetymonitor::SafetyMonitorError;
use safetymonitor::discover_alpaca_safetymonitors;
use switch::AlpacaSwitchController;
use switch::AlpacaSwitchInfo;
use switch::SwitchError;
use switch::discover_alpaca_switches;
use time_utils::*;

// UDL-generated scaffolding
uniffi::include_scaffolding!("polar_core");

/// Library version
fn polar_core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Discover ASCOM Alpaca devices on local network via UDP broadcast.
fn discover_alpaca(timeout_ms: u32) -> Vec<String> {
    MountController::discover_alpaca(timeout_ms)
}

/// List available serial ports for LX200/USB mount connections.
fn list_serial_ports() -> Vec<String> {
    MountController::list_serial_ports()
}
