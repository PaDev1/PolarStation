//! ASCOM Alpaca HTTP client for focuser control.
//!
//! Alpaca REST API: https://ascom-standards.org/api/

use std::time::Duration;

use super::FocuserError;
use crate::alpaca_common;

/// ASCOM Alpaca focuser HTTP client.
pub struct AlpacaFocuserClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaFocuserClient {
    pub fn new(host: &str, port: u16, device_number: u32) -> Result<Self, FocuserError> {
        let base_url = format!(
            "http://{}:{}/api/v1/focuser/{}",
            host, port, device_number
        );
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        let agent = config.new_agent();
        Ok(Self {
            base_url,
            client_id: 4,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent,
        })
    }

    fn next_tid(&self) -> u32 {
        self.transaction_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    fn get_value(&self, property: &str) -> Result<String, FocuserError> {
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
                eprintln!("[AlpacaFocuser] GET {} failed: {}", property, e);
                FocuserError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| FocuserError::InvalidResponse)?;
        alpaca_common::extract_json_value(&body).map_err(|_| FocuserError::InvalidResponse)
    }

    fn get_int(&self, property: &str) -> Result<i64, FocuserError> {
        self.get_value(property)?
            .parse()
            .map_err(|_| FocuserError::InvalidResponse)
    }

    fn get_float(&self, property: &str) -> Result<f64, FocuserError> {
        self.get_value(property)?
            .parse()
            .map_err(|_| FocuserError::InvalidResponse)
    }

    fn get_bool(&self, property: &str) -> Result<bool, FocuserError> {
        let val = self.get_value(property)?;
        match val.to_lowercase().as_str() {
            "true" => Ok(true),
            "false" => Ok(false),
            _ => Err(FocuserError::InvalidResponse),
        }
    }

    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), FocuserError> {
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
                eprintln!("[AlpacaFocuser] PUT {} failed: {}", method, e);
                FocuserError::CommunicationError
            })?;

        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| FocuserError::InvalidResponse)?;

        alpaca_common::check_alpaca_error(&body).map_err(|msg| {
            eprintln!("[AlpacaFocuser] {}", msg);
            FocuserError::CommandRejected
        })
    }

    pub fn connect(&self) -> Result<super::AlpacaFocuserInfo, FocuserError> {
        self.put("connected", &[("Connected", "true")])?;

        let name = self
            .get_value("name")
            .unwrap_or_else(|_| "Focuser".into());
        let position = self.get_int("position").unwrap_or(0) as i32;
        let max_step = self.get_int("maxstep").unwrap_or(0) as i32;
        let temperature = self.get_float("temperature").unwrap_or(-999.0);
        let temp_comp = self.get_bool("tempcomp").unwrap_or(false);

        Ok(super::AlpacaFocuserInfo {
            name,
            position,
            max_step,
            temperature,
            temp_comp,
        })
    }

    pub fn disconnect(&self) -> Result<(), FocuserError> {
        self.put("connected", &[("Connected", "false")])
    }

    pub fn get_position(&self) -> Result<i32, FocuserError> {
        self.get_int("position").map(|v| v as i32)
    }

    pub fn get_max_step(&self) -> Result<i32, FocuserError> {
        self.get_int("maxstep").map(|v| v as i32)
    }

    pub fn is_moving(&self) -> Result<bool, FocuserError> {
        self.get_bool("ismoving")
    }

    pub fn get_temperature(&self) -> Result<f64, FocuserError> {
        self.get_float("temperature")
    }

    pub fn get_temp_comp(&self) -> Result<bool, FocuserError> {
        self.get_bool("tempcomp")
    }

    pub fn set_temp_comp(&self, enabled: bool) -> Result<(), FocuserError> {
        let val = if enabled { "true" } else { "false" };
        self.put("tempcomp", &[("TempComp", val)])
    }

    pub fn move_to(&self, position: i32) -> Result<(), FocuserError> {
        let val = position.to_string();
        self.put("move", &[("Position", &val)])
    }

    pub fn halt(&self) -> Result<(), FocuserError> {
        self.put("halt", &[])
    }
}

/// Query the Alpaca management API for configured focuser devices.
pub fn discover_alpaca_focusers(
    host: String,
    port: u16,
) -> Result<Vec<crate::camera::AlpacaDeviceInfo>, FocuserError> {
    let devices = alpaca_common::discover_alpaca_devices(&host, port, "focuser")
        .map_err(|msg| {
            eprintln!("[AlpacaFocuser] discovery failed: {}", msg);
            FocuserError::CommunicationError
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
