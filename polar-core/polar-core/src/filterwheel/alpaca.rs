//! ASCOM Alpaca HTTP client for filter wheel control.
//!
//! Alpaca REST API: https://ascom-standards.org/api/

use std::time::Duration;

use super::FilterWheelError;

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
        extract_json_value(&body)
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

        check_alpaca_error(&body)
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
        parse_string_array(&body)
    }
}

/// Parse "Value": ["name1", "name2", ...] from JSON response.
fn parse_string_array(json: &str) -> Result<Vec<String>, FilterWheelError> {
    let key = "\"Value\"";
    let pos = json.find(key).ok_or(FilterWheelError::InvalidResponse)?;
    let rest = &json[pos + key.len()..];
    let rest = rest.trim_start();
    let rest = rest
        .strip_prefix(':')
        .ok_or(FilterWheelError::InvalidResponse)?;
    let rest = rest.trim_start();
    let rest = rest
        .strip_prefix('[')
        .ok_or(FilterWheelError::InvalidResponse)?;

    // Find closing bracket
    let end = rest.find(']').unwrap_or(rest.len());
    let array_content = &rest[..end];

    let mut names = Vec::new();
    for item in array_content.split(',') {
        let item = item.trim();
        if item.starts_with('"') && item.ends_with('"') && item.len() >= 2 {
            names.push(item[1..item.len() - 1].to_string());
        }
    }
    Ok(names)
}

fn extract_json_value(json: &str) -> Result<String, FilterWheelError> {
    let key = "\"Value\"";
    let pos = json.find(key).ok_or(FilterWheelError::InvalidResponse)?;
    let rest = &json[pos + key.len()..];
    let rest = rest.trim_start();
    let rest = rest
        .strip_prefix(':')
        .ok_or(FilterWheelError::InvalidResponse)?;
    let rest = rest.trim_start();

    if rest.starts_with('"') {
        let end = rest[1..].find('"').ok_or(FilterWheelError::InvalidResponse)?;
        Ok(rest[1..1 + end].to_string())
    } else {
        let end = rest
            .find(|c: char| c == ',' || c == '}' || c == ']' || c.is_whitespace())
            .unwrap_or(rest.len());
        Ok(rest[..end].to_string())
    }
}

fn check_alpaca_error(json: &str) -> Result<(), FilterWheelError> {
    if let Some(pos) = json.find("\"ErrorNumber\"") {
        let rest = &json[pos + 13..];
        if let Some(colon) = rest.find(':') {
            let val = rest[colon + 1..].trim_start();
            let end = val
                .find(|c: char| c == ',' || c == '}')
                .unwrap_or(val.len());
            let num = val[..end].trim();
            if num != "0" {
                let msg = extract_error_message(json);
                eprintln!("[AlpacaFilterWheel] Error {num}: {msg}");
                return Err(FilterWheelError::CommandRejected);
            }
        }
    }
    Ok(())
}

fn extract_error_message(json: &str) -> String {
    let key = "\"ErrorMessage\"";
    if let Some(pos) = json.find(key) {
        let rest = &json[pos + key.len()..];
        let rest = rest.trim_start();
        if let Some(rest) = rest.strip_prefix(':') {
            let rest = rest.trim_start();
            if rest.starts_with('"') {
                if let Some(end) = rest[1..].find('"') {
                    return rest[1..1 + end].to_string();
                }
            }
        }
    }
    "unknown".to_string()
}

/// Query the Alpaca management API for configured filter wheel devices.
pub fn discover_alpaca_filterwheels(
    host: String,
    port: u16,
) -> Result<Vec<super::super::camera::AlpacaDeviceInfo>, FilterWheelError> {
    let url = format!(
        "http://{}:{}/management/v1/configureddevices",
        host, port
    );
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(10)))
        .build();
    let agent = config.new_agent();
    let mut resp = agent
        .get(&url)
        .call()
        .map_err(|_| FilterWheelError::CommunicationError)?;
    let body = resp
        .body_mut()
        .read_to_string()
        .map_err(|_| FilterWheelError::InvalidResponse)?;

    let mut wheels = Vec::new();
    let value_key = "\"Value\"";
    let pos = match body.find(value_key) {
        Some(p) => p,
        None => return Ok(wheels),
    };
    let rest = &body[pos + value_key.len()..];
    let rest = rest.trim_start();
    let rest = match rest.strip_prefix(':') {
        Some(r) => r.trim_start(),
        None => return Ok(wheels),
    };
    let rest = match rest.strip_prefix('[') {
        Some(r) => r,
        None => return Ok(wheels),
    };

    for chunk in rest.split('{').skip(1) {
        let device_name = extract_string_field(chunk, "DeviceName").unwrap_or_default();
        let device_type = extract_string_field(chunk, "DeviceType").unwrap_or_default();
        let device_number = extract_number_field(chunk, "DeviceNumber").unwrap_or(0);

        if device_type.eq_ignore_ascii_case("filterwheel") {
            wheels.push(super::super::camera::AlpacaDeviceInfo {
                device_name,
                device_type,
                device_number,
            });
        }
    }

    Ok(wheels)
}

fn extract_string_field(json_chunk: &str, field: &str) -> Option<String> {
    let key = format!("\"{}\"", field);
    let pos = json_chunk.find(&key)?;
    let rest = &json_chunk[pos + key.len()..];
    let rest = rest.trim_start().strip_prefix(':')?;
    let rest = rest.trim_start().strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

fn extract_number_field(json_chunk: &str, field: &str) -> Option<u32> {
    let key = format!("\"{}\"", field);
    let pos = json_chunk.find(&key)?;
    let rest = &json_chunk[pos + key.len()..];
    let rest = rest.trim_start().strip_prefix(':')?;
    let rest = rest.trim_start();
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    rest[..end].parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

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
