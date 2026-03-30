//! ASCOM Alpaca HTTP client for telescope control.
//!
//! Alpaca REST API: https://ascom-standards.org/api/
//! Generic implementation — works with any Alpaca-compliant mount.

use std::net::UdpSocket;
use std::time::Duration;

use crate::coordinates::MountStatus;
use super::{MountError, TrackingRate};

/// ASCOM Alpaca HTTP client.
pub struct AlpacaClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaClient {
    pub fn new(host: &str, port: u16, device_number: u32) -> Result<Self, MountError> {
        let base_url = format!("http://{}:{}/api/v1/telescope/{}", host, port, device_number);
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(10)))
            .build();
        let agent = config.new_agent();
        Ok(Self {
            base_url,
            client_id: 1,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent,
        })
    }

    fn next_transaction_id(&self) -> u32 {
        self.transaction_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    /// GET a property from the Alpaca API, returning the JSON "Value" field.
    fn get_value(&self, property: &str) -> Result<String, MountError> {
        let url = format!("{}/{}?ClientID={}&ClientTransactionID={}",
            self.base_url, property, self.client_id, self.next_transaction_id());

        let mut response = self.agent.get(&url)
            .call()
            .map_err(|_| MountError::CommunicationError)?;

        let body = response.body_mut()
            .read_to_string()
            .map_err(|_| MountError::InvalidResponse)?;

        // Parse minimal JSON to extract "Value" field
        extract_json_value(&body)
    }

    /// GET a float property.
    fn get_float(&self, property: &str) -> Result<f64, MountError> {
        let val = self.get_value(property)?;
        val.parse::<f64>().map_err(|_| MountError::InvalidResponse)
    }

    /// GET a bool property.
    fn get_bool(&self, property: &str) -> Result<bool, MountError> {
        let val = self.get_value(property)?;
        match val.as_str() {
            "true" | "True" => Ok(true),
            "false" | "False" => Ok(false),
            _ => Err(MountError::InvalidResponse),
        }
    }

    /// GET an integer property.
    fn get_int(&self, property: &str) -> Result<i64, MountError> {
        let val = self.get_value(property)?;
        val.parse::<i64>().map_err(|_| MountError::InvalidResponse)
    }

    /// PUT (set) a property on the Alpaca API.
    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), MountError> {
        let url = format!("{}/{}", self.base_url, method);
        let tid = self.next_transaction_id();

        let mut form_data = vec![
            ("ClientID", self.client_id.to_string()),
            ("ClientTransactionID", tid.to_string()),
        ];
        for (k, v) in params {
            form_data.push((k, v.to_string()));
        }

        let form_pairs: Vec<(&str, &str)> = form_data.iter()
            .map(|(k, v)| (*k, v.as_str()))
            .collect();

        let mut response = self.agent.put(&url)
            .send_form(form_pairs)
            .map_err(|_| MountError::CommunicationError)?;

        let body = response.body_mut()
            .read_to_string()
            .map_err(|_| MountError::InvalidResponse)?;

        // Check for Alpaca error in response
        check_alpaca_error(&body)
    }

    pub fn set_connected_flag(&self, connected: bool) -> Result<(), MountError> {
        let val = if connected { "true" } else { "false" };
        self.put("connected", &[("Connected", val)])
    }

    pub fn get_status(&self) -> Result<MountStatus, MountError> {
        let ra_hours = self.get_float("rightascension")?;
        let dec_deg = self.get_float("declination")?;
        let tracking = self.get_bool("tracking").unwrap_or(false);
        let slewing = self.get_bool("slewing").unwrap_or(false);

        let tracking_rate = self.get_int("trackingrate").unwrap_or(0) as u8;
        let at_park = self.get_bool("atpark").unwrap_or(false);

        let alt_deg = self.get_float("altitude").unwrap_or(f64::NAN);
        let az_deg = self.get_float("azimuth").unwrap_or(f64::NAN);

        Ok(MountStatus {
            connected: true,
            ra_hours,
            dec_deg,
            alt_deg,
            az_deg,
            tracking,
            slewing,
            tracking_rate,
            at_park,
        })
    }

    /// Lightweight status: only RA, Dec, tracking, slewing (4 GETs instead of 8).
    /// Use for idle polling when alt/az, tracking_rate, and at_park are not needed.
    pub fn get_status_light(&self) -> Result<MountStatus, MountError> {
        let ra_hours = self.get_float("rightascension")?;
        let dec_deg = self.get_float("declination")?;
        let tracking = self.get_bool("tracking").unwrap_or(false);
        let slewing = self.get_bool("slewing").unwrap_or(false);

        Ok(MountStatus {
            connected: true,
            ra_hours,
            dec_deg,
            alt_deg: f64::NAN,
            az_deg: f64::NAN,
            tracking,
            slewing,
            tracking_rate: 0,
            at_park: false,
        })
    }

    pub fn slew_ra_degrees(&self, degrees: f64) -> Result<(), MountError> {
        // Get current position
        let current_ra = self.get_float("rightascension")?;
        let current_dec = self.get_float("declination")?;

        // Convert degrees to hours for RA
        let target_ra = (current_ra + degrees / 15.0).rem_euclid(24.0);

        // Start async slew and return immediately.
        // Swift polling will detect slewing==false when complete.
        let ra_str = target_ra.to_string();
        let dec_str = current_dec.to_string();
        self.put("slewtocoordinatesasync", &[
            ("RightAscension", &ra_str),
            ("Declination", &dec_str),
        ])
    }

    pub fn set_tracking(&self, enabled: bool) -> Result<(), MountError> {
        let val = if enabled { "true" } else { "false" };
        self.put("tracking", &[("Tracking", val)])
    }

    pub fn goto_radec(&self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        let ra_str = ra_hours.to_string();
        let dec_str = dec_deg.to_string();
        self.put("slewtocoordinatesasync", &[
            ("RightAscension", &ra_str),
            ("Declination", &dec_str),
        ])
    }

    pub fn set_tracking_rate(&self, rate: TrackingRate) -> Result<(), MountError> {
        let val = (rate as u8).to_string();
        self.put("trackingrate", &[("TrackingRate", &val)])
    }

    pub fn move_axis(&self, axis: u8, rate_deg_per_sec: f64) -> Result<(), MountError> {
        let axis_str = axis.to_string();
        let rate_str = rate_deg_per_sec.to_string();
        self.put("moveaxis", &[
            ("Axis", &axis_str),
            ("Rate", &rate_str),
        ])
    }

    /// ASCOM PulseGuide: direction 0=North, 1=South, 2=East, 3=West.
    /// The mount handles the timing internally — this blocks until the pulse completes.
    pub fn pulse_guide(&self, direction: u8, duration_ms: u32) -> Result<(), MountError> {
        let dir_str = direction.to_string();
        let dur_str = duration_ms.to_string();
        self.put("pulseguide", &[
            ("Direction", &dir_str),
            ("Duration", &dur_str),
        ])
    }

    pub fn park(&self) -> Result<(), MountError> {
        self.put("park", &[])
    }

    pub fn unpark(&self) -> Result<(), MountError> {
        self.put("unpark", &[])
    }

    pub fn sync_position(&self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        println!("[Alpaca] Sync position: RA={:.4}h Dec={:.4}°", ra_hours, dec_deg);
        let ra_str = ra_hours.to_string();
        let dec_str = dec_deg.to_string();
        let result = self.put("synctocoordinates", &[
            ("RightAscension", &ra_str),
            ("Declination", &dec_str),
        ]);
        match &result {
            Ok(()) => println!("[Alpaca] Sync succeeded"),
            Err(e) => println!("[Alpaca] Sync failed: {:?}", e),
        }
        result
    }

    pub fn abort(&self) -> Result<(), MountError> {
        self.put("abortslew", &[])
    }

    pub fn find_home(&self) -> Result<(), MountError> {
        self.put("findhome", &[])
    }
}

impl super::MountBackendTrait for AlpacaClient {
    fn get_status(&mut self) -> Result<MountStatus, MountError> {
        AlpacaClient::get_status(self)
    }

    fn get_status_light(&mut self) -> Result<MountStatus, MountError> {
        AlpacaClient::get_status_light(self)
    }

    fn slew_ra_degrees(&mut self, degrees: f64) -> Result<(), MountError> {
        AlpacaClient::slew_ra_degrees(self, degrees)
    }

    fn set_tracking(&mut self, enabled: bool) -> Result<(), MountError> {
        AlpacaClient::set_tracking(self, enabled)
    }

    fn abort(&mut self) -> Result<(), MountError> {
        AlpacaClient::abort(self)
    }

    fn disconnect(&mut self) -> Result<(), MountError> {
        self.set_connected_flag(false).ok();
        Ok(())
    }

    fn backend_name(&self) -> &str {
        "Alpaca"
    }

    fn goto_radec(&mut self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        AlpacaClient::goto_radec(self, ra_hours, dec_deg)
    }

    fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), MountError> {
        AlpacaClient::set_tracking_rate(self, rate)
    }

    fn sync_position(&mut self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        AlpacaClient::sync_position(self, ra_hours, dec_deg)
    }

    fn move_axis(&mut self, axis: u8, rate_deg_per_sec: f64) -> Result<(), MountError> {
        AlpacaClient::move_axis(self, axis, rate_deg_per_sec)
    }

    fn pulse_guide(&mut self, direction: u8, duration_ms: u32) -> Result<(), MountError> {
        AlpacaClient::pulse_guide(self, direction, duration_ms)
    }

    fn park(&mut self) -> Result<(), MountError> {
        AlpacaClient::park(self)
    }

    fn unpark(&mut self) -> Result<(), MountError> {
        AlpacaClient::unpark(self)
    }

    fn find_home(&mut self) -> Result<(), MountError> {
        AlpacaClient::find_home(self)
    }
}

/// Discover Alpaca devices via UDP broadcast on port 32227.
pub fn discover(timeout: Duration) -> Vec<String> {
    let mut results = Vec::new();

    let socket = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return results,
    };

    let _ = socket.set_broadcast(true);
    let _ = socket.set_read_timeout(Some(timeout));

    // ASCOM Alpaca discovery protocol
    let discovery_msg = b"{\"alpacaport\":0}";
    let _ = socket.send_to(discovery_msg, "255.255.255.255:32227");

    let mut buf = [0u8; 1024];
    while let Ok((n, addr)) = socket.recv_from(&mut buf) {
        if let Ok(response) = std::str::from_utf8(&buf[..n]) {
            // Parse "AlpacaPort" from JSON response
            if let Some(port) = extract_alpaca_port(response) {
                results.push(format!("{}:{}", addr.ip(), port));
            }
        }
    }

    results
}

/// Query the Alpaca management API for configured telescope (mount) devices.
/// Same pattern as camera and filter wheel discovery.
pub fn discover_alpaca_mounts(
    host: String,
    port: u16,
) -> Result<Vec<crate::camera::AlpacaDeviceInfo>, MountError> {
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
        .map_err(|_| MountError::CommunicationError)?;
    let body = resp
        .body_mut()
        .read_to_string()
        .map_err(|_| MountError::InvalidResponse)?;

    let mut mounts = Vec::new();
    let value_key = "\"Value\"";
    let pos = match body.find(value_key) {
        Some(p) => p,
        None => return Ok(mounts),
    };
    let rest = &body[pos + value_key.len()..];
    let rest = rest.trim_start();
    let rest = match rest.strip_prefix(':') {
        Some(r) => r.trim_start(),
        None => return Ok(mounts),
    };
    let rest = match rest.strip_prefix('[') {
        Some(r) => r,
        None => return Ok(mounts),
    };

    for chunk in rest.split('{').skip(1) {
        let device_name = extract_mount_string_field(chunk, "DeviceName").unwrap_or_default();
        let device_type = extract_mount_string_field(chunk, "DeviceType").unwrap_or_default();
        let device_number = extract_mount_number_field(chunk, "DeviceNumber").unwrap_or(0);

        if device_type.eq_ignore_ascii_case("telescope") {
            mounts.push(crate::camera::AlpacaDeviceInfo {
                device_name,
                device_type,
                device_number,
            });
        }
    }

    Ok(mounts)
}

fn extract_mount_string_field(json_chunk: &str, field: &str) -> Option<String> {
    let key = format!("\"{}\"", field);
    let pos = json_chunk.find(&key)?;
    let rest = &json_chunk[pos + key.len()..];
    let rest = rest.trim_start().strip_prefix(':')?;
    let rest = rest.trim_start().strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

fn extract_mount_number_field(json_chunk: &str, field: &str) -> Option<u32> {
    let key = format!("\"{}\"", field);
    let pos = json_chunk.find(&key)?;
    let rest = &json_chunk[pos + key.len()..];
    let rest = rest.trim_start().strip_prefix(':')?;
    let rest = rest.trim_start();
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    rest[..end].parse().ok()
}

/// Extract the "Value" field from an Alpaca JSON response.
/// Minimal parser — avoids pulling in serde_json.
fn extract_json_value(json: &str) -> Result<String, MountError> {
    // Look for "Value": or "Value" :
    let key = "\"Value\"";
    let pos = json.find(key).ok_or(MountError::InvalidResponse)?;
    let rest = &json[pos + key.len()..];
    let rest = rest.trim_start();
    let rest = rest.strip_prefix(':').ok_or(MountError::InvalidResponse)?;
    let rest = rest.trim_start();

    // Value could be number, bool, string, or null
    if rest.starts_with('"') {
        // String value
        let end = rest[1..].find('"').ok_or(MountError::InvalidResponse)?;
        Ok(rest[1..1 + end].to_string())
    } else {
        // Number, bool, or null — read until comma, brace, or whitespace
        let end = rest.find(|c: char| c == ',' || c == '}' || c == ']' || c.is_whitespace())
            .unwrap_or(rest.len());
        Ok(rest[..end].to_string())
    }
}

/// Check for Alpaca error in response (ErrorNumber != 0).
fn check_alpaca_error(json: &str) -> Result<(), MountError> {
    if let Some(pos) = json.find("\"ErrorNumber\"") {
        let rest = &json[pos + 13..];
        if let Some(colon) = rest.find(':') {
            let val = rest[colon + 1..].trim_start();
            let end = val.find(|c: char| c == ',' || c == '}').unwrap_or(val.len());
            let num = val[..end].trim();
            if num != "0" {
                // Extract ErrorMessage for diagnostics
                let msg = extract_error_message(json);
                eprintln!("[Alpaca] Error {num}: {msg}");
                eprintln!("[Alpaca] Full response: {json}");
                return Err(MountError::CommandRejected);
            }
        }
    }
    Ok(())
}

/// Extract "ErrorMessage" from Alpaca JSON response.
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

/// Extract AlpacaPort from discovery response JSON.
fn extract_alpaca_port(json: &str) -> Option<u16> {
    let key = "\"AlpacaPort\"";
    let pos = json.find(key)?;
    let rest = &json[pos + key.len()..];
    let rest = rest.trim_start().strip_prefix(':')?;
    let rest = rest.trim_start();
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    rest[..end].parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_json_value_number() {
        let json = r#"{"Value": 12.345, "ErrorNumber": 0}"#;
        assert_eq!(extract_json_value(json).unwrap(), "12.345");
    }

    #[test]
    fn test_extract_json_value_bool() {
        let json = r#"{"Value": true, "ErrorNumber": 0}"#;
        assert_eq!(extract_json_value(json).unwrap(), "true");
    }

    #[test]
    fn test_extract_json_value_string() {
        let json = r#"{"Value": "hello", "ErrorNumber": 0}"#;
        assert_eq!(extract_json_value(json).unwrap(), "hello");
    }

    #[test]
    fn test_check_alpaca_error_ok() {
        let json = r#"{"ErrorNumber": 0, "ErrorMessage": ""}"#;
        assert!(check_alpaca_error(json).is_ok());
    }

    #[test]
    fn test_check_alpaca_error_fail() {
        let json = r#"{"ErrorNumber": 1024, "ErrorMessage": "Not connected"}"#;
        assert!(check_alpaca_error(json).is_err());
    }

    #[test]
    fn test_extract_alpaca_port() {
        let json = r#"{"AlpacaPort": 11111}"#;
        assert_eq!(extract_alpaca_port(json), Some(11111));
    }
}
