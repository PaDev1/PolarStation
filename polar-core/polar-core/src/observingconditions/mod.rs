//! Observing conditions (weather station) with ASCOM Alpaca backend.

use std::sync::Mutex;

pub mod alpaca;

pub use alpaca::discover_alpaca_observingconditions;

/// Errors from observing conditions operations.
#[derive(Debug, thiserror::Error)]
pub enum ObservingConditionsError {
    #[error("Not connected to weather station")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Weather station rejected command")]
    CommandRejected,
    #[error("Invalid response from weather station")]
    InvalidResponse,
}

/// Observing conditions information from Alpaca.
pub struct AlpacaObservingConditionsInfo {
    pub name: String,
}

/// Controller exposed to Swift via UniFFI.
pub struct AlpacaObservingConditionsController {
    client: Mutex<Option<alpaca::AlpacaObservingConditionsClient>>,
}

impl AlpacaObservingConditionsController {
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
    ) -> Result<AlpacaObservingConditionsInfo, ObservingConditionsError> {
        let client =
            alpaca::AlpacaObservingConditionsClient::new(&host, port as u16, device_number)?;
        let info = client.connect()?;
        let mut guard = self.client.lock().unwrap();
        *guard = Some(client);
        Ok(info)
    }

    pub fn disconnect(&self) -> Result<(), ObservingConditionsError> {
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

    pub fn get_temperature(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_temperature(),
            None => -999.0,
        }
    }

    pub fn get_humidity(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_humidity(),
            None => -999.0,
        }
    }

    pub fn get_dewpoint(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_dewpoint(),
            None => -999.0,
        }
    }

    pub fn get_pressure(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_pressure(),
            None => -999.0,
        }
    }

    pub fn get_wind_speed(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_wind_speed(),
            None => -999.0,
        }
    }

    pub fn get_wind_direction(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_wind_direction(),
            None => -999.0,
        }
    }

    pub fn get_cloud_cover(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_cloud_cover(),
            None => -999.0,
        }
    }

    pub fn get_sky_brightness(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_sky_brightness(),
            None => -999.0,
        }
    }

    pub fn get_sky_temperature(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_sky_temperature(),
            None => -999.0,
        }
    }

    pub fn get_star_fwhm(&self) -> f64 {
        let guard = self.client.lock().unwrap();
        match guard.as_ref() {
            Some(client) => client.get_star_fwhm(),
            None => -999.0,
        }
    }
}
