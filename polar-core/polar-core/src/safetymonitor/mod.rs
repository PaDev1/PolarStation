//! Safety monitor with ASCOM Alpaca backend.

use std::sync::Mutex;

pub mod alpaca;

pub use alpaca::discover_alpaca_safetymonitors;

/// Errors from safety monitor operations.
#[derive(Debug, thiserror::Error)]
pub enum SafetyMonitorError {
    #[error("Not connected to safety monitor")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Safety monitor rejected command")]
    CommandRejected,
    #[error("Invalid response from safety monitor")]
    InvalidResponse,
}

/// Safety monitor information from Alpaca.
pub struct AlpacaSafetyMonitorInfo {
    pub name: String,
    pub is_safe: bool,
}

/// Controller exposed to Swift via UniFFI.
pub struct AlpacaSafetyMonitorController {
    client: Mutex<Option<alpaca::AlpacaSafetyMonitorClient>>,
}

impl AlpacaSafetyMonitorController {
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
    ) -> Result<AlpacaSafetyMonitorInfo, SafetyMonitorError> {
        let client =
            alpaca::AlpacaSafetyMonitorClient::new(&host, port as u16, device_number)?;
        let info = client.connect()?;
        let mut guard = self.client.lock().unwrap();
        *guard = Some(client);
        Ok(info)
    }

    pub fn disconnect(&self) -> Result<(), SafetyMonitorError> {
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

    pub fn is_safe(&self) -> Result<bool, SafetyMonitorError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.is_safe(),
            None => Err(SafetyMonitorError::NotConnected),
        }
    }
}
