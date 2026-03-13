//! Filter wheel control with ASCOM Alpaca backend.

use std::sync::Mutex;

pub mod alpaca;

pub use alpaca::discover_alpaca_filterwheels;

/// Errors from filter wheel operations.
#[derive(Debug, thiserror::Error)]
pub enum FilterWheelError {
    #[error("Not connected to filter wheel")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Filter wheel rejected command")]
    CommandRejected,
    #[error("Invalid response from filter wheel")]
    InvalidResponse,
}

/// Filter wheel information from Alpaca.
pub struct AlpacaFilterWheelInfo {
    pub name: String,
    pub filter_names: Vec<String>,
    pub position: i16,
}

/// Controller exposed to Swift via UniFFI.
pub struct AlpacaFilterWheelController {
    client: Mutex<Option<alpaca::AlpacaFilterWheelClient>>,
}

impl AlpacaFilterWheelController {
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
    ) -> Result<AlpacaFilterWheelInfo, FilterWheelError> {
        let client =
            alpaca::AlpacaFilterWheelClient::new(&host, port as u16, device_number)?;
        let info = client.connect()?;
        let mut guard = self.client.lock().unwrap();
        *guard = Some(client);
        Ok(info)
    }

    pub fn disconnect(&self) -> Result<(), FilterWheelError> {
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

    pub fn get_position(&self) -> Result<i16, FilterWheelError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_position(),
            None => Err(FilterWheelError::NotConnected),
        }
    }

    pub fn set_position(&self, position: i16) -> Result<(), FilterWheelError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.set_position(position),
            None => Err(FilterWheelError::NotConnected),
        }
    }

    pub fn get_names(&self) -> Result<Vec<String>, FilterWheelError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_names(),
            None => Err(FilterWheelError::NotConnected),
        }
    }
}
