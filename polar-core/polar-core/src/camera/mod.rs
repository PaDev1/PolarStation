//! Camera control with pluggable backends.
//!
//! Currently supports ASCOM Alpaca cameras over HTTP.
//! ZWO ASI USB cameras are handled directly in Swift via the C SDK.

use std::sync::Mutex;

pub mod alpaca;

pub use alpaca::{AlpacaDeviceInfo, discover_alpaca_cameras};

/// Errors from camera operations.
#[derive(Debug, thiserror::Error)]
pub enum CameraError {
    #[error("Not connected to camera")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Camera rejected command")]
    CommandRejected,
    #[error("Invalid response from camera")]
    InvalidResponse,
    #[error("Timeout waiting for camera")]
    Timeout,
    #[error("Exposure in progress")]
    ExposureInProgress,
    #[error("Image not ready")]
    ImageNotReady,
}

/// Camera information from Alpaca.
pub struct AlpacaCameraInfo {
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub sensor_type: u8,
    pub max_bin: u8,
    pub max_adu: u32,
    pub has_cooler: bool,
    pub pixel_size_x: f64,
    pub pixel_size_y: f64,
    pub bayer_offset_x: u8,
    pub bayer_offset_y: u8,
    pub gain_min: i32,
    pub gain_max: i32,
    pub gain: i32,
}

/// Controller exposed to Swift via UniFFI.
pub struct AlpacaCameraController {
    client: Mutex<Option<alpaca::AlpacaCameraClient>>,
}

impl AlpacaCameraController {
    pub fn new() -> Self {
        Self {
            client: Mutex::new(None),
        }
    }

    pub fn connect(&self, host: String, port: u32, device_number: u32) -> Result<AlpacaCameraInfo, CameraError> {
        let client = alpaca::AlpacaCameraClient::new(&host, port as u16, device_number)?;
        let info = client.connect()?;
        let mut guard = self.client.lock().unwrap();
        *guard = Some(client);
        Ok(info)
    }

    pub fn disconnect(&self) -> Result<(), CameraError> {
        let mut guard = self.client.lock().unwrap();
        if let Some(ref client) = *guard {
            client.disconnect().ok();
        }
        *guard = None;
        Ok(())
    }

    pub fn is_connected(&self) -> bool {
        self.client.lock().unwrap().is_some()
    }

    pub fn set_binning(&self, bin: u8) -> Result<(), CameraError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.set_binning(bin),
            None => Err(CameraError::NotConnected),
        }
    }

    pub fn set_gain(&self, gain: i32) -> Result<(), CameraError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.set_gain(gain),
            None => Err(CameraError::NotConnected),
        }
    }

    pub fn start_exposure(&self, duration_secs: f64) -> Result<(), CameraError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.start_exposure(duration_secs),
            None => Err(CameraError::NotConnected),
        }
    }

    pub fn is_image_ready(&self) -> Result<bool, CameraError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.is_image_ready(),
            None => Err(CameraError::NotConnected),
        }
    }

    pub fn camera_state(&self) -> Result<u8, CameraError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.camera_state(),
            None => Err(CameraError::NotConnected),
        }
    }

    /// Download the last captured image as raw pixel bytes (16-bit little-endian).
    pub fn download_image(&self) -> Result<Vec<u8>, CameraError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.download_image_bytes(),
            None => Err(CameraError::NotConnected),
        }
    }

    pub fn get_temperature(&self) -> Result<f64, CameraError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_temperature(),
            None => Err(CameraError::NotConnected),
        }
    }

    pub fn set_cooler(&self, enabled: bool, target_celsius: f64) -> Result<(), CameraError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.set_cooler(enabled, target_celsius),
            None => Err(CameraError::NotConnected),
        }
    }

    pub fn abort_exposure(&self) -> Result<(), CameraError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.abort_exposure(),
            None => Err(CameraError::NotConnected),
        }
    }
}
