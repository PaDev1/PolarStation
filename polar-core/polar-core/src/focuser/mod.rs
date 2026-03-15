//! Focuser control with ASCOM Alpaca backend.

use std::sync::Mutex;

pub mod alpaca;

pub use alpaca::discover_alpaca_focusers;

/// Errors from focuser operations.
#[derive(Debug, thiserror::Error)]
pub enum FocuserError {
    #[error("Not connected to focuser")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Focuser rejected command")]
    CommandRejected,
    #[error("Invalid response from focuser")]
    InvalidResponse,
}

/// Focuser information from Alpaca.
pub struct AlpacaFocuserInfo {
    pub name: String,
    pub position: i32,
    pub max_step: i32,
    pub temperature: f64,
    pub temp_comp: bool,
}

/// Controller exposed to Swift via UniFFI.
pub struct AlpacaFocuserController {
    client: Mutex<Option<alpaca::AlpacaFocuserClient>>,
}

impl AlpacaFocuserController {
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
    ) -> Result<AlpacaFocuserInfo, FocuserError> {
        let client =
            alpaca::AlpacaFocuserClient::new(&host, port as u16, device_number)?;
        let info = client.connect()?;
        let mut guard = self.client.lock().unwrap();
        *guard = Some(client);
        Ok(info)
    }

    pub fn disconnect(&self) -> Result<(), FocuserError> {
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

    pub fn get_position(&self) -> Result<i32, FocuserError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_position(),
            None => Err(FocuserError::NotConnected),
        }
    }

    pub fn get_max_step(&self) -> Result<i32, FocuserError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_max_step(),
            None => Err(FocuserError::NotConnected),
        }
    }

    pub fn is_moving(&self) -> Result<bool, FocuserError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.is_moving(),
            None => Err(FocuserError::NotConnected),
        }
    }

    pub fn get_temperature(&self) -> Result<f64, FocuserError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_temperature(),
            None => Err(FocuserError::NotConnected),
        }
    }

    pub fn get_temp_comp(&self) -> Result<bool, FocuserError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_temp_comp(),
            None => Err(FocuserError::NotConnected),
        }
    }

    pub fn set_temp_comp(&self, enabled: bool) -> Result<(), FocuserError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.set_temp_comp(enabled),
            None => Err(FocuserError::NotConnected),
        }
    }

    pub fn move_to(&self, position: i32) -> Result<(), FocuserError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.move_to(position),
            None => Err(FocuserError::NotConnected),
        }
    }

    pub fn halt(&self) -> Result<(), FocuserError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.halt(),
            None => Err(FocuserError::NotConnected),
        }
    }
}
