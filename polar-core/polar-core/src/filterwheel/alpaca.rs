//! ASCOM Alpaca HTTP client for filter wheel control.
//!
//! Alpaca REST API: https://ascom-standards.org/api/

use std::time::Duration;

use super::FilterWheelError;
use crate::alpaca_common;

/// ASCOM Alpaca filter wheel HTTP client.
pub struct AlpacaFilterWheelClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaFilterWheelClient {
    pub fn new(host: &str, port: u16, device_number: u32) -> Result<Self, FilterWheelError> {
        let base_url = format!(
            "http://{}:{}/api/v1/filterwheel/{}",
            host, port, device_number
        );
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        let agent = config.new_agent();
        Ok(Self {
            base_url,
            client_id: 3,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent,
        })
    }

    fn next_tid(&self) -> u32 {
        self.transaction_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    /// GET a property, returning the raw "Value" string.
    fn get_value(&self, property: &str) -> Result<String, FilterWheelError> {
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
                eprintln!("[AlpacaFilterWheel] GET {} failed: {}", property, e);
                FilterWheelError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| FilterWheelError::InvalidResponse)?;
        alpaca_common::extract_json_value(&body).map_err(|_| FilterWheelError::InvalidResponse)
    }

    fn get_int(&self, property: &str) -> Result<i64, FilterWheelError> {
        self.get_value(property)?
            .parse()
            .map_err(|_| FilterWheelError::InvalidResponse)
    }

    /// PUT (set) a property.
    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), FilterWheelError> {
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
                eprintln!("[AlpacaFilterWheel] PUT {} failed: {}", method, e);
                FilterWheelError::CommunicationError
            })?;

        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| FilterWheelError::InvalidResponse)?;

        alpaca_common::check_alpaca_error(&body).map_err(|msg| {
            eprintln!("[AlpacaFilterWheel] {}", msg);
            FilterWheelError::CommandRejected
        })
    }

    pub fn connect(&self) -> Result<super::AlpacaFilterWheelInfo, FilterWheelError> {
        self.put("connected", &[("Connected", "true")])?;

        let name = self
            .get_value("name")
            .unwrap_or_else(|_| "Filter Wheel".into());
        let filter_names = self.get_names()?;
        let position = self.get_int("position").unwrap_or(-1) as i16;

        Ok(super::AlpacaFilterWheelInfo {
            name,
            filter_names,
            position,
        })
    }

    pub fn disconnect(&self) -> Result<(), FilterWheelError> {
        self.put("connected", &[("Connected", "false")])
    }

    pub fn get_position(&self) -> Result<i16, FilterWheelError> {
        self.get_int("position").map(|v| v as i16)
    }

    pub fn set_position(&self, position: i16) -> Result<(), FilterWheelError> {
        let val = position.to_string();
        self.put("position", &[("Position", &val)])
    }

    pub fn get_names(&self) -> Result<Vec<String>, FilterWheelError> {
        let url = format!(
            "{}/names?ClientID={}&ClientTransactionID={}",
            self.base_url,
            self.client_id,
            self.next_tid()
        );
        let mut resp = self
            .agent
            .get(&url)
            .call()
            .map_err(|e| {
                eprintln!("[AlpacaFilterWheel] GET names failed: {}", e);
                FilterWheelError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| FilterWheelError::InvalidResponse)?;
        alpaca_common::parse_string_array(&body).map_err(|_| FilterWheelError::InvalidResponse)
    }
}

/// Query the Alpaca management API for configured filter wheel devices.
pub fn discover_alpaca_filterwheels(
    host: String,
    port: u16,
) -> Result<Vec<super::super::camera::AlpacaDeviceInfo>, FilterWheelError> {
    let devices = alpaca_common::discover_alpaca_devices(&host, port, "filterwheel")
        .map_err(|msg| {
            eprintln!("[AlpacaFilterWheel] discovery failed: {}", msg);
            FilterWheelError::CommunicationError
        })?;

    Ok(devices
        .into_iter()
        .map(|(name, dtype, num)| super::super::camera::AlpacaDeviceInfo {
            device_name: name,
            device_type: dtype,
            device_number: num,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use crate::alpaca_common::*;

    #[test]
    fn test_parse_string_array() {
        let json = r#"{"Value": ["Red", "Green", "Blue", "Luminance"], "ErrorNumber": 0}"#;
        let names = parse_string_array(json).unwrap();
        assert_eq!(names, vec!["Red", "Green", "Blue", "Luminance"]);
    }

    #[test]
    fn test_parse_empty_array() {
        let json = r#"{"Value": [], "ErrorNumber": 0}"#;
        let names = parse_string_array(json).unwrap();
        assert!(names.is_empty());
    }

    #[test]
    fn test_extract_json_value_int() {
        let json = r#"{"Value": 2, "ErrorNumber": 0}"#;
        assert_eq!(extract_json_value(json).unwrap(), "2");
    }

    #[test]
    fn test_check_error_ok() {
        let json = r#"{"ErrorNumber": 0, "ErrorMessage": ""}"#;
        assert!(check_alpaca_error(json).is_ok());
    }

    #[test]
    fn test_check_error_fail() {
        let json = r#"{"ErrorNumber": 1024, "ErrorMessage": "Not connected"}"#;
        assert!(check_alpaca_error(json).is_err());
    }
}
