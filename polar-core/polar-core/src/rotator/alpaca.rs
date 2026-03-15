//! ASCOM Alpaca HTTP client for rotator control.
//!
//! Alpaca REST API: https://ascom-standards.org/api/

use std::time::Duration;

use super::RotatorError;
use crate::alpaca_common;

/// ASCOM Alpaca rotator HTTP client.
pub struct AlpacaRotatorClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaRotatorClient {
    pub fn new(host: &str, port: u16, device_number: u32) -> Result<Self, RotatorError> {
        let base_url = format!(
            "http://{}:{}/api/v1/rotator/{}",
            host, port, device_number
        );
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        let agent = config.new_agent();
        Ok(Self {
            base_url,
            client_id: 6,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent,
        })
    }

    fn next_tid(&self) -> u32 {
        self.transaction_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    fn get_value(&self, property: &str) -> Result<String, RotatorError> {
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
                eprintln!("[AlpacaRotator] GET {} failed: {}", property, e);
                RotatorError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| RotatorError::InvalidResponse)?;
        alpaca_common::extract_json_value(&body).map_err(|_| RotatorError::InvalidResponse)
    }

    fn get_float(&self, property: &str) -> Result<f64, RotatorError> {
        self.get_value(property)?
            .parse()
            .map_err(|_| RotatorError::InvalidResponse)
    }

    fn get_bool(&self, property: &str) -> Result<bool, RotatorError> {
        let val = self.get_value(property)?;
        match val.to_lowercase().as_str() {
            "true" => Ok(true),
            "false" => Ok(false),
            _ => Err(RotatorError::InvalidResponse),
        }
    }

    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), RotatorError> {
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
                eprintln!("[AlpacaRotator] PUT {} failed: {}", method, e);
                RotatorError::CommunicationError
            })?;

        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| RotatorError::InvalidResponse)?;

        alpaca_common::check_alpaca_error(&body).map_err(|msg| {
            eprintln!("[AlpacaRotator] {}", msg);
            RotatorError::CommandRejected
        })
    }

    pub fn connect(&self) -> Result<super::AlpacaRotatorInfo, RotatorError> {
        self.put("connected", &[("Connected", "true")])?;

        let name = self
            .get_value("name")
            .unwrap_or_else(|_| "Rotator".into());
        let position = self.get_float("position").unwrap_or(0.0);
        let mechanical_position = self.get_float("mechanicalposition").unwrap_or(0.0);
        let is_moving = self.get_bool("ismoving").unwrap_or(false);

        Ok(super::AlpacaRotatorInfo {
            name,
            position,
            mechanical_position,
            is_moving,
        })
    }

    pub fn disconnect(&self) -> Result<(), RotatorError> {
        self.put("connected", &[("Connected", "false")])
    }

    pub fn get_position(&self) -> Result<f64, RotatorError> {
        self.get_float("position")
    }

    pub fn get_mechanical_position(&self) -> Result<f64, RotatorError> {
        self.get_float("mechanicalposition")
    }

    pub fn is_moving(&self) -> Result<bool, RotatorError> {
        self.get_bool("ismoving")
    }

    pub fn move_relative(&self, position: f64) -> Result<(), RotatorError> {
        let val = position.to_string();
        self.put("move", &[("Position", &val)])
    }

    pub fn move_absolute(&self, position: f64) -> Result<(), RotatorError> {
        let val = position.to_string();
        self.put("moveabsolute", &[("Position", &val)])
    }

    pub fn halt(&self) -> Result<(), RotatorError> {
        self.put("halt", &[])
    }
}

/// Query the Alpaca management API for configured rotator devices.
pub fn discover_alpaca_rotators(
    host: String,
    port: u16,
) -> Result<Vec<crate::camera::AlpacaDeviceInfo>, RotatorError> {
    let devices = alpaca_common::discover_alpaca_devices(&host, port, "rotator")
        .map_err(|msg| {
            eprintln!("[AlpacaRotator] discovery failed: {}", msg);
            RotatorError::CommunicationError
        })?;

    Ok(devices
        .into_iter()
        .map(|(name, dtype, num)| crate::camera::AlpacaDeviceInfo {
            device_name: name,
            device_type: dtype,
            device_number: num,
        })
        .collect())
}
