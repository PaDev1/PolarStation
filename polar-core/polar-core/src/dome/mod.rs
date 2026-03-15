//! Dome control with ASCOM Alpaca backend.

use std::sync::Mutex;

pub mod alpaca;

pub use alpaca::discover_alpaca_domes;

/// Errors from dome operations.
#[derive(Debug, thiserror::Error)]
pub enum DomeError {
    #[error("Not connected to dome")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Dome rejected command")]
    CommandRejected,
    #[error("Invalid response from dome")]
    InvalidResponse,
}

/// Dome information from Alpaca.
pub struct AlpacaDomeInfo {
    pub name: String,
    pub azimuth: f64,
    pub shutter_status: i32,
    pub at_home: bool,
    pub at_park: bool,
}

/// Controller exposed to Swift via UniFFI.
pub struct AlpacaDomeController {
    client: Mutex<Option<alpaca::AlpacaDomeClient>>,
}

impl AlpacaDomeController {
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
    ) -> Result<AlpacaDomeInfo, DomeError> {
        let client =
            alpaca::AlpacaDomeClient::new(&host, port as u16, device_number)?;
        let info = client.connect()?;
        let mut guard = self.client.lock().unwrap();
        *guard = Some(client);
        Ok(info)
    }

    pub fn disconnect(&self) -> Result<(), DomeError> {
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

    pub fn get_azimuth(&self) -> Result<f64, DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_azimuth(),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn get_shutter_status(&self) -> Result<i32, DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_shutter_status(),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn is_slewing(&self) -> Result<bool, DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.is_slewing(),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn at_home(&self) -> Result<bool, DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.at_home(),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn at_park(&self) -> Result<bool, DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.at_park(),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn slew_to_azimuth(&self, azimuth: f64) -> Result<(), DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.slew_to_azimuth(azimuth),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn open_shutter(&self) -> Result<(), DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.open_shutter(),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn close_shutter(&self) -> Result<(), DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.close_shutter(),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn park(&self) -> Result<(), DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.park(),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn find_home(&self) -> Result<(), DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.find_home(),
            None => Err(DomeError::NotConnected),
        }
    }

    pub fn abort_slew(&self) -> Result<(), DomeError> {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.abort_slew(),
            None => Err(DomeError::NotConnected),
        }
    }
}
