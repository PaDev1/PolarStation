//! Cover calibrator control with ASCOM Alpaca backend.

use std::sync::Mutex;

pub mod alpaca;

pub use alpaca::discover_alpaca_covercalibrators;

/// Errors from cover calibrator operations.
#[derive(Debug, thiserror::Error)]
pub enum CoverCalibratorError {
    #[error("Not connected to cover calibrator")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Cover calibrator rejected command")]
    CommandRejected,
    #[error("Invalid response from cover calibrator")]
    InvalidResponse,
}

/// Cover calibrator information from Alpaca.
pub struct AlpacaCoverCalibratorInfo {
    pub name: String,
    pub cover_state: i32,
    pub calibrator_state: i32,
    pub brightness: i32,
    pub max_brightness: i32,
}

/// Controller exposed to Swift via UniFFI.
pub struct AlpacaCoverCalibratorController {
    client: Mutex<Option<alpaca::AlpacaCoverCalibratorClient>>,
}

impl AlpacaCoverCalibratorController {
    pub fn new() -> Self {
        Self { client: Mutex::new(None) }
    }

    pub fn connect(&self, host: String, port: u32, device_number: u32) -> Result<AlpacaCoverCalibratorInfo, CoverCalibratorError> {
        let client = alpaca::AlpacaCoverCalibratorClient::new(&host, port as u16, device_number)?;
        let info = client.connect()?;
        *self.client.lock().unwrap() = Some(client);
        Ok(info)
    }

    pub fn disconnect(&self) -> Result<(), CoverCalibratorError> {
        let mut guard = self.client.lock().unwrap();
        if let Some(ref client) = *guard { client.disconnect().ok(); }
        *guard = None;
        Ok(())
    }

    pub fn is_connected(&self) -> bool { self.client.lock().unwrap().is_some() }

    pub fn get_cover_state(&self) -> Result<i32, CoverCalibratorError> {
        self.client.lock().unwrap().as_ref().map(|c| c.get_cover_state()).unwrap_or(Err(CoverCalibratorError::NotConnected))
    }

    pub fn get_calibrator_state(&self) -> Result<i32, CoverCalibratorError> {
        self.client.lock().unwrap().as_ref().map(|c| c.get_calibrator_state()).unwrap_or(Err(CoverCalibratorError::NotConnected))
    }

    pub fn get_brightness(&self) -> Result<i32, CoverCalibratorError> {
        self.client.lock().unwrap().as_ref().map(|c| c.get_brightness()).unwrap_or(Err(CoverCalibratorError::NotConnected))
    }

    pub fn get_max_brightness(&self) -> Result<i32, CoverCalibratorError> {
        self.client.lock().unwrap().as_ref().map(|c| c.get_max_brightness()).unwrap_or(Err(CoverCalibratorError::NotConnected))
    }

    pub fn open_cover(&self) -> Result<(), CoverCalibratorError> {
        self.client.lock().unwrap().as_ref().map(|c| c.open_cover()).unwrap_or(Err(CoverCalibratorError::NotConnected))
    }

    pub fn close_cover(&self) -> Result<(), CoverCalibratorError> {
        self.client.lock().unwrap().as_ref().map(|c| c.close_cover()).unwrap_or(Err(CoverCalibratorError::NotConnected))
    }

    pub fn halt_cover(&self) -> Result<(), CoverCalibratorError> {
        self.client.lock().unwrap().as_ref().map(|c| c.halt_cover()).unwrap_or(Err(CoverCalibratorError::NotConnected))
    }

    pub fn calibrator_on(&self, brightness: i32) -> Result<(), CoverCalibratorError> {
        self.client.lock().unwrap().as_ref().map(|c| c.calibrator_on(brightness)).unwrap_or(Err(CoverCalibratorError::NotConnected))
    }

    pub fn calibrator_off(&self) -> Result<(), CoverCalibratorError> {
        self.client.lock().unwrap().as_ref().map(|c| c.calibrator_off()).unwrap_or(Err(CoverCalibratorError::NotConnected))
    }
}
