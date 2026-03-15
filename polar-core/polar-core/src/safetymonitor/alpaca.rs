//! ASCOM Alpaca HTTP client for safety monitor.
//!
//! Alpaca REST API: https://ascom-standards.org/api/

use std::time::Duration;

use super::SafetyMonitorError;
use crate::alpaca_common;

/// ASCOM Alpaca safety monitor HTTP client.
pub struct AlpacaSafetyMonitorClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaSafetyMonitorClient {
    pub fn new(host: &str, port: u16, device_number: u32) -> Result<Self, SafetyMonitorError> {
        let base_url = format!(
            "http://{}:{}/api/v1/safetymonitor/{}",
            host, port, device_number
        );
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        let agent = config.new_agent();
        Ok(Self {
            base_url,
            client_id: 8,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent,
        })
    }

    fn next_tid(&self) -> u32 {
        self.transaction_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    fn get_value(&self, property: &str) -> Result<String, SafetyMonitorError> {
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
                eprintln!("[AlpacaSafetyMonitor] GET {} failed: {}", property, e);
                SafetyMonitorError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| SafetyMonitorError::InvalidResponse)?;
        alpaca_common::extract_json_value(&body).map_err(|_| SafetyMonitorError::InvalidResponse)
    }

    fn get_bool(&self, property: &str) -> Result<bool, SafetyMonitorError> {
        let val = self.get_value(property)?;
        match val.to_lowercase().as_str() {
            "true" => Ok(true),
            "false" => Ok(false),
            _ => Err(SafetyMonitorError::InvalidResponse),
        }
    }

    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), SafetyMonitorError> {
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
                eprintln!("[AlpacaSafetyMonitor] PUT {} failed: {}", method, e);
                SafetyMonitorError::CommunicationError
            })?;

        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| SafetyMonitorError::InvalidResponse)?;

        alpaca_common::check_alpaca_error(&body).map_err(|msg| {
            eprintln!("[AlpacaSafetyMonitor] {}", msg);
            SafetyMonitorError::CommandRejected
        })
    }

    pub fn connect(&self) -> Result<super::AlpacaSafetyMonitorInfo, SafetyMonitorError> {
        self.put("connected", &[("Connected", "true")])?;

        let name = self
            .get_value("name")
            .unwrap_or_else(|_| "Safety Monitor".into());
        let is_safe = self.get_bool("issafe").unwrap_or(false);

        Ok(super::AlpacaSafetyMonitorInfo { name, is_safe })
    }

    pub fn disconnect(&self) -> Result<(), SafetyMonitorError> {
        self.put("connected", &[("Connected", "false")])
    }

    pub fn is_safe(&self) -> Result<bool, SafetyMonitorError> {
        self.get_bool("issafe")
    }
}

/// Query the Alpaca management API for configured safety monitor devices.
pub fn discover_alpaca_safetymonitors(
    host: String,
    port: u16,
) -> Result<Vec<crate::camera::AlpacaDeviceInfo>, SafetyMonitorError> {
    let devices = alpaca_common::discover_alpaca_devices(&host, port, "safetymonitor")
        .map_err(|msg| {
            eprintln!("[AlpacaSafetyMonitor] discovery failed: {}", msg);
            SafetyMonitorError::CommunicationError
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
