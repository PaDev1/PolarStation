//! ASCOM Alpaca HTTP client for observing conditions (weather station).
//!
//! Alpaca REST API: https://ascom-standards.org/api/
//!
//! Each weather property may not be implemented by all devices,
//! so getters return -999.0 on error.

use std::time::Duration;

use super::ObservingConditionsError;
use crate::alpaca_common;

/// ASCOM Alpaca observing conditions HTTP client.
pub struct AlpacaObservingConditionsClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaObservingConditionsClient {
    pub fn new(
        host: &str,
        port: u16,
        device_number: u32,
    ) -> Result<Self, ObservingConditionsError> {
        let base_url = format!(
            "http://{}:{}/api/v1/observingconditions/{}",
            host, port, device_number
        );
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        let agent = config.new_agent();
        Ok(Self {
            base_url,
            client_id: 9,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent,
        })
    }

    fn next_tid(&self) -> u32 {
        self.transaction_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    fn get_value(&self, property: &str) -> Result<String, ObservingConditionsError> {
        let url = format!(
            "{}/{}?ClientID={}&ClientTransactionID={}",
            self.base_url,
            property,
            self.client_id,
            self.next_tid()
        );
        let mut resp = self
            .agent
            .get(&url)
            .call()
            .map_err(|e| {
                eprintln!("[AlpacaObservingConditions] GET {} failed: {}", property, e);
                ObservingConditionsError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| ObservingConditionsError::InvalidResponse)?;
        alpaca_common::extract_json_value(&body)
            .map_err(|_| ObservingConditionsError::InvalidResponse)
    }

    fn get_float_optional(&self, property: &str) -> f64 {
        self.get_value(property)
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(-999.0)
    }

    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), ObservingConditionsError> {
        let url = format!("{}/{}", self.base_url, method);
        let tid = self.next_tid();

        let mut form_data = vec![
            ("ClientID", self.client_id.to_string()),
            ("ClientTransactionID", tid.to_string()),
        ];
        for (k, v) in params {
            form_data.push((k, v.to_string()));
        }

        let form_pairs: Vec<(&str, &str)> =
            form_data.iter().map(|(k, v)| (*k, v.as_str())).collect();

        let mut resp = self
            .agent
            .put(&url)
            .send_form(form_pairs)
            .map_err(|e| {
                eprintln!("[AlpacaObservingConditions] PUT {} failed: {}", method, e);
                ObservingConditionsError::CommunicationError
            })?;

        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| ObservingConditionsError::InvalidResponse)?;

        alpaca_common::check_alpaca_error(&body).map_err(|msg| {
            eprintln!("[AlpacaObservingConditions] {}", msg);
            ObservingConditionsError::CommandRejected
        })
    }

    pub fn connect(
        &self,
    ) -> Result<super::AlpacaObservingConditionsInfo, ObservingConditionsError> {
        self.put("connected", &[("Connected", "true")])?;

        let name = self
            .get_value("name")
            .unwrap_or_else(|_| "Weather Station".into());

        Ok(super::AlpacaObservingConditionsInfo { name })
    }

    pub fn disconnect(&self) -> Result<(), ObservingConditionsError> {
        self.put("connected", &[("Connected", "false")])
    }

    pub fn get_temperature(&self) -> f64 {
        self.get_float_optional("temperature")
    }

    pub fn get_humidity(&self) -> f64 {
        self.get_float_optional("humidity")
    }

    pub fn get_dewpoint(&self) -> f64 {
        self.get_float_optional("dewpoint")
    }

    pub fn get_pressure(&self) -> f64 {
        self.get_float_optional("pressure")
    }

    pub fn get_wind_speed(&self) -> f64 {
        self.get_float_optional("windspeed")
    }

    pub fn get_wind_direction(&self) -> f64 {
        self.get_float_optional("winddirection")
    }

    pub fn get_cloud_cover(&self) -> f64 {
        self.get_float_optional("cloudcover")
    }

    pub fn get_sky_brightness(&self) -> f64 {
        self.get_float_optional("skybrightness")
    }

    pub fn get_sky_temperature(&self) -> f64 {
        self.get_float_optional("skytemperature")
    }

    pub fn get_star_fwhm(&self) -> f64 {
        self.get_float_optional("starfwhm")
    }
}

/// Query the Alpaca management API for configured observing conditions devices.
pub fn discover_alpaca_observingconditions(
    host: String,
    port: u16,
) -> Result<Vec<crate::camera::AlpacaDeviceInfo>, ObservingConditionsError> {
    let devices =
        alpaca_common::discover_alpaca_devices(&host, port, "observingconditions").map_err(
            |msg| {
                eprintln!("[AlpacaObservingConditions] discovery failed: {}", msg);
                ObservingConditionsError::CommunicationError
            },
        )?;

    Ok(devices
        .into_iter()
        .map(|(name, dtype, num)| crate::camera::AlpacaDeviceInfo {
            device_name: name,
            device_type: dtype,
            device_number: num,
        })
        .collect())
}
