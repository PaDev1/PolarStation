pub mod camera;
pub mod coordinates;
pub mod filterwheel;
pub mod mount;
pub mod plate_solver;
pub mod polar_error;
pub mod time_utils;

use camera::AlpacaCameraController;
use camera::AlpacaCameraInfo;
use camera::AlpacaDeviceInfo;
use camera::CameraError;
use camera::discover_alpaca_cameras;
use coordinates::*;
use filterwheel::AlpacaFilterWheelController;
use filterwheel::AlpacaFilterWheelInfo;
use filterwheel::FilterWheelError;
use filterwheel::discover_alpaca_filterwheels;
use mount::MountController;
use mount::MountError;
use plate_solver::*;
use polar_error::*;
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
