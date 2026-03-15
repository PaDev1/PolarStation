//! ASCOM Alpaca HTTP client for cover calibrator control.

use std::time::Duration;
use super::CoverCalibratorError;
use crate::alpaca_common;

pub struct AlpacaCoverCalibratorClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaCoverCalibratorClient {
    pub fn new(host: &str, port: u16, device_number: u32) -> Result<Self, CoverCalibratorError> {
        let base_url = format!("http://{}:{}/api/v1/covercalibrator/{}", host, port, device_number);
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        Ok(Self {
            base_url,
            client_id: 10,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent: config.new_agent(),
        })
    }

    fn next_tid(&self) -> u32 {
        self.transaction_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    fn get_value(&self, property: &str) -> Result<String, CoverCalibratorError> {
        let url = format!("{}/{}?ClientID={}&ClientTransactionID={}", self.base_url, property, self.client_id, self.next_tid());
        let mut resp = self.agent.get(&url).call().map_err(|e| {
            eprintln!("[AlpacaCoverCalibrator] GET {} failed: {}", property, e);
            CoverCalibratorError::CommunicationError
        })?;
        let body = resp.body_mut().read_to_string().map_err(|_| CoverCalibratorError::InvalidResponse)?;
        alpaca_common::extract_json_value(&body).map_err(|_| CoverCalibratorError::InvalidResponse)
    }

    fn get_int(&self, property: &str) -> Result<i64, CoverCalibratorError> {
        self.get_value(property)?.parse().map_err(|_| CoverCalibratorError::InvalidResponse)
    }

    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), CoverCalibratorError> {
        let url = format!("{}/{}", self.base_url, method);
        let tid = self.next_tid();
        let mut form_data = vec![("ClientID", self.client_id.to_string()), ("ClientTransactionID", tid.to_string())];
        for (k, v) in params { form_data.push((k, v.to_string())); }
        let form_pairs: Vec<(&str, &str)> = form_data.iter().map(|(k, v)| (*k, v.as_str())).collect();
        let mut resp = self.agent.put(&url).send_form(form_pairs).map_err(|e| {
            eprintln!("[AlpacaCoverCalibrator] PUT {} failed: {}", method, e);
            CoverCalibratorError::CommunicationError
        })?;
        let body = resp.body_mut().read_to_string().map_err(|_| CoverCalibratorError::InvalidResponse)?;
        alpaca_common::check_alpaca_error(&body).map_err(|msg| {
            eprintln!("[AlpacaCoverCalibrator] {}", msg);
            CoverCalibratorError::CommandRejected
        })
    }

    pub fn connect(&self) -> Result<super::AlpacaCoverCalibratorInfo, CoverCalibratorError> {
        self.put("connected", &[("Connected", "true")])?;
        let name = self.get_value("name").unwrap_or_else(|_| "Cover Calibrator".into());
        let cover_state = self.get_int("coverstate").unwrap_or(4) as i32;
        let calibrator_state = self.get_int("calibratorstate").unwrap_or(4) as i32;
        let brightness = self.get_int("brightness").unwrap_or(0) as i32;
        let max_brightness = self.get_int("maxbrightness").unwrap_or(0) as i32;
        Ok(super::AlpacaCoverCalibratorInfo { name, cover_state, calibrator_state, brightness, max_brightness })
    }

    pub fn disconnect(&self) -> Result<(), CoverCalibratorError> { self.put("connected", &[("Connected", "false")]) }
    pub fn get_cover_state(&self) -> Result<i32, CoverCalibratorError> { self.get_int("coverstate").map(|v| v as i32) }
    pub fn get_calibrator_state(&self) -> Result<i32, CoverCalibratorError> { self.get_int("calibratorstate").map(|v| v as i32) }
    pub fn get_brightness(&self) -> Result<i32, CoverCalibratorError> { self.get_int("brightness").map(|v| v as i32) }
    pub fn get_max_brightness(&self) -> Result<i32, CoverCalibratorError> { self.get_int("maxbrightness").map(|v| v as i32) }
    pub fn open_cover(&self) -> Result<(), CoverCalibratorError> { self.put("opencover", &[]) }
    pub fn close_cover(&self) -> Result<(), CoverCalibratorError> { self.put("closecover", &[]) }
    pub fn halt_cover(&self) -> Result<(), CoverCalibratorError> { self.put("haltcover", &[]) }
    pub fn calibrator_on(&self, brightness: i32) -> Result<(), CoverCalibratorError> {
        let val = brightness.to_string();
        self.put("calibratoron", &[("Brightness", &val)])
    }
    pub fn calibrator_off(&self) -> Result<(), CoverCalibratorError> { self.put("calibratoroff", &[]) }
}

pub fn discover_alpaca_covercalibrators(
    host: String, port: u16,
) -> Result<Vec<crate::camera::AlpacaDeviceInfo>, CoverCalibratorError> {
    let devices = alpaca_common::discover_alpaca_devices(&host, port, "covercalibrator").map_err(|msg| {
        eprintln!("[AlpacaCoverCalibrator] discovery failed: {}", msg);
        CoverCalibratorError::CommunicationError
    })?;
    Ok(devices.into_iter().map(|(name, dtype, num)| crate::camera::AlpacaDeviceInfo {
        device_name: name, device_type: dtype, device_number: num,
    }).collect())
}
