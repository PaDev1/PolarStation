//! Switch control with ASCOM Alpaca backend.

use std::sync::Mutex;

pub mod alpaca;

pub use alpaca::discover_alpaca_switches;

/// Errors from switch operations.
#[derive(Debug, thiserror::Error)]
pub enum SwitchError {
    #[error("Not connected to switch")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Switch rejected command")]
    CommandRejected,
    #[error("Invalid response from switch")]
    InvalidResponse,
}

/// Switch information from Alpaca.
pub struct AlpacaSwitchInfo {
    pub name: String,
    pub max_switch: i32,
}

/// Controller exposed to Swift via UniFFI.
pub struct AlpacaSwitchController {
    client: Mutex<Option<alpaca::AlpacaSwitchClient>>,
}

impl AlpacaSwitchController {
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
    ) -> Result<AlpacaSwitchInfo, SwitchError> {
        let client =
            alpaca::AlpacaSwitchClient::new(&host, port as u16, device_number)?;
        let info = client.connect()?;
        let mut guard = self.client.lock().unwrap();
        *guard = Some(client);
        Ok(info)
    }

    pub fn disconnect(&self) -> Result<(), SwitchError> {
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

    pub fn get_max_switch(&self) -> Result<i32, SwitchError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_max_switch(),
            None => Err(SwitchError::NotConnected),
        }
    }

    pub fn get_switch_name(&self, id: i32) -> Result<String, SwitchError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_switch_name(id),
            None => Err(SwitchError::NotConnected),
        }
    }

    pub fn get_switch(&self, id: i32) -> Result<bool, SwitchError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_switch(id),
            None => Err(SwitchError::NotConnected),
        }
    }

    pub fn get_switch_value(&self, id: i32) -> Result<f64, SwitchError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_switch_value(id),
            None => Err(SwitchError::NotConnected),
        }
    }

    pub fn set_switch(&self, id: i32, state: bool) -> Result<(), SwitchError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.set_switch(id, state),
            None => Err(SwitchError::NotConnected),
        }
    }

    pub fn set_switch_value(&self, id: i32, value: f64) -> Result<(), SwitchError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.set_switch_value(id, value),
            None => Err(SwitchError::NotConnected),
        }
    }

    pub fn get_min_switch_value(&self, id: i32) -> Result<f64, SwitchError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_min_switch_value(id),
            None => Err(SwitchError::NotConnected),
        }
    }

    pub fn get_max_switch_value(&self, id: i32) -> Result<f64, SwitchError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_max_switch_value(id),
            None => Err(SwitchError::NotConnected),
        }
    }
}
