//! ASCOM Alpaca HTTP client for dome control.
//!
//! Alpaca REST API: https://ascom-standards.org/api/

use std::time::Duration;

use super::DomeError;
use crate::alpaca_common;

/// ASCOM Alpaca dome HTTP client.
pub struct AlpacaDomeClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaDomeClient {
    pub fn new(host: &str, port: u16, device_number: u32) -> Result<Self, DomeError> {
        let base_url = format!(
            "http://{}:{}/api/v1/dome/{}",
            host, port, device_number
        );
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        let agent = config.new_agent();
        Ok(Self {
            base_url,
            client_id: 5,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent,
        })
    }

    fn next_tid(&self) -> u32 {
        self.transaction_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    fn get_value(&self, property: &str) -> Result<String, DomeError> {
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
                eprintln!("[AlpacaDome] GET {} failed: {}", property, e);
                DomeError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| DomeError::InvalidResponse)?;
        alpaca_common::extract_json_value(&body).map_err(|_| DomeError::InvalidResponse)
    }

    fn get_int(&self, property: &str) -> Result<i64, DomeError> {
        self.get_value(property)?
            .parse()
            .map_err(|_| DomeError::InvalidResponse)
    }

    fn get_float(&self, property: &str) -> Result<f64, DomeError> {
        self.get_value(property)?
            .parse()
            .map_err(|_| DomeError::InvalidResponse)
    }

    fn get_bool(&self, property: &str) -> Result<bool, DomeError> {
        let val = self.get_value(property)?;
        match val.to_lowercase().as_str() {
            "true" => Ok(true),
            "false" => Ok(false),
            _ => Err(DomeError::InvalidResponse),
        }
    }

    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), DomeError> {
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
                eprintln!("[AlpacaDome] PUT {} failed: {}", method, e);
                DomeError::CommunicationError
            })?;

        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| DomeError::InvalidResponse)?;

        alpaca_common::check_alpaca_error(&body).map_err(|msg| {
            eprintln!("[AlpacaDome] {}", msg);
            DomeError::CommandRejected
        })
    }

    pub fn connect(&self) -> Result<super::AlpacaDomeInfo, DomeError> {
        self.put("connected", &[("Connected", "true")])?;

        let name = self
            .get_value("name")
            .unwrap_or_else(|_| "Dome".into());
        let azimuth = self.get_float("azimuth").unwrap_or(0.0);
        let shutter_status = self.get_int("shutterstatus").unwrap_or(4) as i32;
        let at_home = self.get_bool("athome").unwrap_or(false);
        let at_park = self.get_bool("atpark").unwrap_or(false);

        Ok(super::AlpacaDomeInfo {
            name,
            azimuth,
            shutter_status,
            at_home,
            at_park,
        })
    }

    pub fn disconnect(&self) -> Result<(), DomeError> {
        self.put("connected", &[("Connected", "false")])
    }

    pub fn get_azimuth(&self) -> Result<f64, DomeError> {
        self.get_float("azimuth")
    }

    pub fn get_shutter_status(&self) -> Result<i32, DomeError> {
        self.get_int("shutterstatus").map(|v| v as i32)
    }

    pub fn is_slewing(&self) -> Result<bool, DomeError> {
        self.get_bool("slewing")
    }

    pub fn at_home(&self) -> Result<bool, DomeError> {
        self.get_bool("athome")
    }

    pub fn at_park(&self) -> Result<bool, DomeError> {
        self.get_bool("atpark")
    }

    pub fn slew_to_azimuth(&self, azimuth: f64) -> Result<(), DomeError> {
        let val = azimuth.to_string();
        self.put("slewtoazimuth", &[("Azimuth", &val)])
    }

    pub fn open_shutter(&self) -> Result<(), DomeError> {
        self.put("openshutter", &[])
    }

    pub fn close_shutter(&self) -> Result<(), DomeError> {
        self.put("closeshutter", &[])
    }

    pub fn park(&self) -> Result<(), DomeError> {
        self.put("park", &[])
    }

    pub fn find_home(&self) -> Result<(), DomeError> {
        self.put("findhome", &[])
    }

    pub fn abort_slew(&self) -> Result<(), DomeError> {
        self.put("abortslew", &[])
    }
}

/// Query the Alpaca management API for configured dome devices.
pub fn discover_alpaca_domes(
    host: String,
    port: u16,
) -> Result<Vec<crate::camera::AlpacaDeviceInfo>, DomeError> {
    let devices = alpaca_common::discover_alpaca_devices(&host, port, "dome")
        .map_err(|msg| {
            eprintln!("[AlpacaDome] discovery failed: {}", msg);
            DomeError::CommunicationError
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
