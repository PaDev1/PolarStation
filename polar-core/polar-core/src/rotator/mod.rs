//! Rotator control with ASCOM Alpaca backend.

use std::sync::Mutex;

pub mod alpaca;

pub use alpaca::discover_alpaca_rotators;

/// Errors from rotator operations.
#[derive(Debug, thiserror::Error)]
pub enum RotatorError {
    #[error("Not connected to rotator")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Rotator rejected command")]
    CommandRejected,
    #[error("Invalid response from rotator")]
    InvalidResponse,
}

/// Rotator information from Alpaca.
pub struct AlpacaRotatorInfo {
    pub name: String,
    pub position: f64,
    pub mechanical_position: f64,
    pub is_moving: bool,
}

/// Controller exposed to Swift via UniFFI.
pub struct AlpacaRotatorController {
    client: Mutex<Option<alpaca::AlpacaRotatorClient>>,
}

impl AlpacaRotatorController {
    pub fn new() -> Self {
        Self {
            client: Mutex::new(None),
        }
    }

    pub fn connect(
        &self,
        host: String,
        port: u32,
        device_number: u32,
    ) -> Result<AlpacaRotatorInfo, RotatorError> {
        let client =
            alpaca::AlpacaRotatorClient::new(&host, port as u16, device_number)?;
        let info = client.connect()?;
        let mut guard = self.client.lock().unwrap();
        *guard = Some(client);
        Ok(info)
    }

    pub fn disconnect(&self) -> Result<(), RotatorError> {
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

    pub fn get_position(&self) -> Result<f64, RotatorError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_position(),
            None => Err(RotatorError::NotConnected),
        }
    }

    pub fn get_mechanical_position(&self) -> Result<f64, RotatorError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_mechanical_position(),
            None => Err(RotatorError::NotConnected),
        }
    }

    pub fn is_moving(&self) -> Result<bool, RotatorError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.is_moving(),
            None => Err(RotatorError::NotConnected),
        }
    }

    pub fn move_relative(&self, position: f64) -> Result<(), RotatorError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.move_relative(position),
            None => Err(RotatorError::NotConnected),
        }
    }

    pub fn move_absolute(&self, position: f64) -> Result<(), RotatorError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.move_absolute(position),
            None => Err(RotatorError::NotConnected),
        }
    }

    pub fn halt(&self) -> Result<(), RotatorError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.halt(),
            None => Err(RotatorError::NotConnected),
        }
    }
}
