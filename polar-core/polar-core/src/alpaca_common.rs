//! Shared helpers for ASCOM Alpaca JSON response parsing.
//!
//! Used by all Alpaca device clients to avoid duplicating parsing logic.

use std::time::Duration;

/// Extract the "Value" field from an Alpaca JSON response as a string.
pub fn extract_json_value(json: &str) -> Result<String, String> {
    let key = "\"Value\"";
    let pos = json.find(key).ok_or("missing Value field")?;
    let rest = &json[pos + key.len()..];
    let rest = rest.trim_start();
    let rest = rest
        .strip_prefix(':')
        .ok_or("missing colon after Value")?;
    let rest = rest.trim_start();

    if rest.starts_with('"') {
        let end = rest[1..].find('"').ok_or("unterminated string")?;
        Ok(rest[1..1 + end].to_string())
    } else {
        let end = rest
            .find(|c: char| c == ',' || c == '}' || c == ']' || c.is_whitespace())
            .unwrap_or(rest.len());
        Ok(rest[..end].to_string())
    }
}

/// Check for Alpaca error in JSON response. Returns `Ok(())` if ErrorNumber is 0 or absent,
/// or `Err(message)` with the error details.
pub fn check_alpaca_error(json: &str) -> Result<(), String> {
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
                return Err(format!("Alpaca error {}: {}", num, msg));
            }
        }
    }
    Ok(())
}

/// Extract the "ErrorMessage" field from an Alpaca JSON response.
pub fn extract_error_message(json: &str) -> String {
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

/// Extract a string field like `"FieldName": "value"` from a JSON chunk.
pub fn extract_string_field(json_chunk: &str, field: &str) -> Option<String> {
    let key = format!("\"{}\"", field);
    let pos = json_chunk.find(&key)?;
    let rest = &json_chunk[pos + key.len()..];
    let rest = rest.trim_start().strip_prefix(':')?;
    let rest = rest.trim_start().strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

/// Extract a numeric field like `"FieldName": 42` from a JSON chunk.
pub fn extract_number_field(json_chunk: &str, field: &str) -> Option<u32> {
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

/// Parse `"Value": ["name1", "name2", ...]` from an Alpaca JSON response.
pub fn parse_string_array(json: &str) -> Result<Vec<String>, String> {
    let key = "\"Value\"";
    let pos = json.find(key).ok_or("missing Value field")?;
    let rest = &json[pos + key.len()..];
    let rest = rest.trim_start();
    let rest = rest.strip_prefix(':').ok_or("missing colon")?;
    let rest = rest.trim_start();
    let rest = rest.strip_prefix('[').ok_or("missing array bracket")?;

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

/// Discover Alpaca devices of a given type from the management API.
pub fn discover_alpaca_devices(
    host: &str,
    port: u16,
    device_type_filter: &str,
) -> Result<Vec<(String, String, u32)>, String> {
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
        .map_err(|e| format!("discovery request failed: {}", e))?;
    let body = resp
        .body_mut()
        .read_to_string()
        .map_err(|e| format!("failed to read discovery response: {}", e))?;

    let mut devices = Vec::new();
    let value_key = "\"Value\"";
    let pos = match body.find(value_key) {
        Some(p) => p,
        None => return Ok(devices),
    };
    let rest = &body[pos + value_key.len()..];
    let rest = rest.trim_start();
    let rest = match rest.strip_prefix(':') {
        Some(r) => r.trim_start(),
        None => return Ok(devices),
    };
    let rest = match rest.strip_prefix('[') {
        Some(r) => r,
        None => return Ok(devices),
    };

    for chunk in rest.split('{').skip(1) {
        let device_name = extract_string_field(chunk, "DeviceName").unwrap_or_default();
        let device_type = extract_string_field(chunk, "DeviceType").unwrap_or_default();
        let device_number = extract_number_field(chunk, "DeviceNumber").unwrap_or(0);

        if device_type.eq_ignore_ascii_case(device_type_filter) {
            devices.push((device_name, device_type, device_number));
        }
    }

    Ok(devices)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_json_value_int() {
        let json = r#"{"Value": 2, "ErrorNumber": 0}"#;
        assert_eq!(extract_json_value(json).unwrap(), "2");
    }

    #[test]
    fn test_extract_json_value_string() {
        let json = r#"{"Value": "hello", "ErrorNumber": 0}"#;
        assert_eq!(extract_json_value(json).unwrap(), "hello");
    }

    #[test]
    fn test_check_error_ok() {
        let json = r#"{"ErrorNumber": 0, "ErrorMessage": ""}"#;
        assert!(check_alpaca_error(json).is_ok());
    }

    #[test]
    fn test_check_error_fail() {
        let json = r#"{"ErrorNumber": 1024, "ErrorMessage": "Not connected"}"#;
        let err = check_alpaca_error(json).unwrap_err();
        assert!(err.contains("1024"));
    }

    #[test]
    fn test_parse_string_array() {
        let json = r#"{"Value": ["Red", "Green", "Blue"], "ErrorNumber": 0}"#;
        let names = parse_string_array(json).unwrap();
        assert_eq!(names, vec!["Red", "Green", "Blue"]);
    }

    #[test]
    fn test_extract_string_field() {
        let chunk = r#""DeviceName": "MyCamera", "DeviceType": "Camera""#;
        assert_eq!(extract_string_field(chunk, "DeviceName").unwrap(), "MyCamera");
    }

    #[test]
    fn test_extract_number_field() {
        let chunk = r#""DeviceNumber": 42, "Other": 1"#;
        assert_eq!(extract_number_field(chunk, "DeviceNumber").unwrap(), 42);
    }
}
