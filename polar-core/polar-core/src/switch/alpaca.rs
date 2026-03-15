//! ASCOM Alpaca HTTP client for switch control.
//!
//! Alpaca REST API: https://ascom-standards.org/api/

use std::time::Duration;

use super::SwitchError;
use crate::alpaca_common;

/// ASCOM Alpaca switch HTTP client.
pub struct AlpacaSwitchClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaSwitchClient {
    pub fn new(host: &str, port: u16, device_number: u32) -> Result<Self, SwitchError> {
        let base_url = format!(
            "http://{}:{}/api/v1/switch/{}",
            host, port, device_number
        );
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        let agent = config.new_agent();
        Ok(Self {
            base_url,
            client_id: 7,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent,
        })
    }

    fn next_tid(&self) -> u32 {
        self.transaction_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    fn get_value(&self, property: &str) -> Result<String, SwitchError> {
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
                eprintln!("[AlpacaSwitch] GET {} failed: {}", property, e);
                SwitchError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| SwitchError::InvalidResponse)?;
        alpaca_common::extract_json_value(&body).map_err(|_| SwitchError::InvalidResponse)
    }

    /// GET a property with an Id query parameter.
    fn get_value_with_id(&self, property: &str, id: i32) -> Result<String, SwitchError> {
        let url = format!(
            "{}/{}?Id={}&ClientID={}&ClientTransactionID={}",
            self.base_url,
            property,
            id,
            self.client_id,
            self.next_tid()
        );
        let mut resp = self
            .agent
            .get(&url)
            .call()
            .map_err(|e| {
                eprintln!("[AlpacaSwitch] GET {}?Id={} failed: {}", property, id, e);
                SwitchError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| SwitchError::InvalidResponse)?;
        alpaca_common::extract_json_value(&body).map_err(|_| SwitchError::InvalidResponse)
    }

    fn get_int(&self, property: &str) -> Result<i64, SwitchError> {
        self.get_value(property)?
            .parse()
            .map_err(|_| SwitchError::InvalidResponse)
    }

    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), SwitchError> {
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
                eprintln!("[AlpacaSwitch] PUT {} failed: {}", method, e);
                SwitchError::CommunicationError
            })?;

        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| SwitchError::InvalidResponse)?;

        alpaca_common::check_alpaca_error(&body).map_err(|msg| {
            eprintln!("[AlpacaSwitch] {}", msg);
            SwitchError::CommandRejected
        })
    }

    pub fn connect(&self) -> Result<super::AlpacaSwitchInfo, SwitchError> {
        self.put("connected", &[("Connected", "true")])?;

        let name = self
            .get_value("name")
            .unwrap_or_else(|_| "Switch".into());
        let max_switch = self.get_int("maxswitch").unwrap_or(0) as i32;

        Ok(super::AlpacaSwitchInfo {
            name,
            max_switch,
        })
    }

    pub fn disconnect(&self) -> Result<(), SwitchError> {
        self.put("connected", &[("Connected", "false")])
    }

    pub fn get_max_switch(&self) -> Result<i32, SwitchError> {
        self.get_int("maxswitch").map(|v| v as i32)
    }

    pub fn get_switch_name(&self, id: i32) -> Result<String, SwitchError> {
        self.get_value_with_id("getswitchname", id)
    }

    pub fn get_switch(&self, id: i32) -> Result<bool, SwitchError> {
        let val = self.get_value_with_id("getswitch", id)?;
        match val.to_lowercase().as_str() {
            "true" => Ok(true),
            "false" => Ok(false),
            _ => Err(SwitchError::InvalidResponse),
        }
    }

    pub fn get_switch_value(&self, id: i32) -> Result<f64, SwitchError> {
        self.get_value_with_id("getswitchvalue", id)?
            .parse()
            .map_err(|_| SwitchError::InvalidResponse)
    }

    pub fn set_switch(&self, id: i32, state: bool) -> Result<(), SwitchError> {
        let id_str = id.to_string();
        let state_str = if state { "true" } else { "false" };
        self.put("setswitch", &[("Id", &id_str), ("State", state_str)])
    }

    pub fn set_switch_value(&self, id: i32, value: f64) -> Result<(), SwitchError> {
        let id_str = id.to_string();
        let val_str = value.to_string();
        self.put("setswitchvalue", &[("Id", &id_str), ("Value", &val_str)])
    }

    pub fn get_min_switch_value(&self, id: i32) -> Result<f64, SwitchError> {
        self.get_value_with_id("minswitchvalue", id)?
            .parse()
            .map_err(|_| SwitchError::InvalidResponse)
    }

    pub fn get_max_switch_value(&self, id: i32) -> Result<f64, SwitchError> {
        self.get_value_with_id("maxswitchvalue", id)?
            .parse()
            .map_err(|_| SwitchError::InvalidResponse)
    }
}

/// Query the Alpaca management API for configured switch devices.
pub fn discover_alpaca_switches(
    host: String,
    port: u16,
) -> Result<Vec<crate::camera::AlpacaDeviceInfo>, SwitchError> {
    let devices = alpaca_common::discover_alpaca_devices(&host, port, "switch")
        .map_err(|msg| {
            eprintln!("[AlpacaSwitch] discovery failed: {}", msg);
            SwitchError::CommunicationError
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
