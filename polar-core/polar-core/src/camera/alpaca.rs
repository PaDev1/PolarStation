//! ASCOM Alpaca HTTP client for camera control.
//!
//! Alpaca REST API: https://ascom-standards.org/api/
//! Uses the binary ImageBytes format for fast image transfer.

use std::time::Duration;

use super::{AlpacaCameraInfo, CameraError};

/// Discovered Alpaca device from the management API.
pub struct AlpacaDeviceInfo {
    pub device_name: String,
    pub device_type: String,
    pub device_number: u32,
}

/// Query the Alpaca management API for configured camera devices.
pub fn discover_alpaca_cameras(host: String, port: u16) -> Result<Vec<AlpacaDeviceInfo>, CameraError> {
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
        .map_err(|_| CameraError::CommunicationError)?;
    let body = resp
        .body_mut()
        .read_to_string()
        .map_err(|_| CameraError::InvalidResponse)?;

    // Parse the "Value" array — each entry has DeviceName, DeviceType, DeviceNumber
    let mut cameras = Vec::new();
    // Find the Value array
    let value_key = "\"Value\"";
    let pos = match body.find(value_key) {
        Some(p) => p,
        None => return Ok(cameras),
    };
    let rest = &body[pos + value_key.len()..];
    let rest = rest.trim_start();
    let rest = match rest.strip_prefix(':') {
        Some(r) => r.trim_start(),
        None => return Ok(cameras),
    };
    let rest = match rest.strip_prefix('[') {
        Some(r) => r,
        None => return Ok(cameras),
    };

    // Split into device objects and extract fields
    for chunk in rest.split('{').skip(1) {
        let device_name = extract_string_field(chunk, "DeviceName").unwrap_or_default();
        let device_type = extract_string_field(chunk, "DeviceType").unwrap_or_default();
        let device_number = extract_number_field(chunk, "DeviceNumber").unwrap_or(0);

        if device_type.eq_ignore_ascii_case("camera") {
            cameras.push(AlpacaDeviceInfo {
                device_name,
                device_type,
                device_number,
            });
        }
    }

    Ok(cameras)
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

/// ASCOM Alpaca camera HTTP client.
pub struct AlpacaCameraClient {
    base_url: String,
    client_id: u32,
    transaction_id: std::sync::atomic::AtomicU32,
    agent: ureq::Agent,
}

impl AlpacaCameraClient {
    pub fn new(host: &str, port: u16, device_number: u32) -> Result<Self, CameraError> {
        let base_url = format!("http://{}:{}/api/v1/camera/{}", host, port, device_number);
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(30)))
            .build();
        let agent = config.new_agent();
        Ok(Self {
            base_url,
            client_id: 2,
            transaction_id: std::sync::atomic::AtomicU32::new(1),
            agent,
        })
    }

    fn next_tid(&self) -> u32 {
        self.transaction_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    /// GET a property, returning the raw "Value" string.
    fn get_value(&self, property: &str) -> Result<String, CameraError> {
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
                eprintln!("[AlpacaCamera] GET {} failed: {}", property, e);
                CameraError::CommunicationError
            })?;
        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| CameraError::InvalidResponse)?;
        extract_json_value(&body)
    }

    fn get_float(&self, property: &str) -> Result<f64, CameraError> {
        self.get_value(property)?
            .parse()
            .map_err(|_| CameraError::InvalidResponse)
    }

    fn get_bool(&self, property: &str) -> Result<bool, CameraError> {
        match self.get_value(property)?.as_str() {
            "true" | "True" => Ok(true),
            "false" | "False" => Ok(false),
            _ => Err(CameraError::InvalidResponse),
        }
    }

    fn get_int(&self, property: &str) -> Result<i64, CameraError> {
        self.get_value(property)?
            .parse()
            .map_err(|_| CameraError::InvalidResponse)
    }

    /// PUT (set) a property.
    fn put(&self, method: &str, params: &[(&str, &str)]) -> Result<(), CameraError> {
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
                eprintln!("[AlpacaCamera] PUT {} failed: {}", method, e);
                CameraError::CommunicationError
            })?;

        let body = resp
            .body_mut()
            .read_to_string()
            .map_err(|_| CameraError::InvalidResponse)?;

        check_alpaca_error(&body)
    }

    pub fn connect(&self) -> Result<AlpacaCameraInfo, CameraError> {
        self.put("connected", &[("Connected", "true")])?;

        let name = self.get_value("name").unwrap_or_else(|_| "Alpaca Camera".into());
        let width = self.get_int("cameraxsize").unwrap_or(0) as u32;
        let height = self.get_int("cameraysize").unwrap_or(0) as u32;
        let sensor_type = self.get_int("sensortype").unwrap_or(0) as u8;
        let max_bin = self.get_int("maxbinx").unwrap_or(1) as u8;
        let max_adu = self.get_int("maxadu").unwrap_or(65535) as u32;
        let has_cooler = self.get_bool("cansetccdtemperature").unwrap_or(false);
        let pixel_size_x = self.get_float("pixelsizex").unwrap_or(0.0);
        let pixel_size_y = self.get_float("pixelsizey").unwrap_or(0.0);
        let bayer_offset_x = self.get_int("bayeroffsetx").unwrap_or(0) as u8;
        let bayer_offset_y = self.get_int("bayeroffsety").unwrap_or(0) as u8;
        let gain_min = self.get_int("gainmin").unwrap_or(0) as i32;
        let gain_max = self.get_int("gainmax").unwrap_or(0) as i32;
        let gain = self.get_int("gain").unwrap_or(0) as i32;

        Ok(AlpacaCameraInfo {
            name,
            width,
            height,
            sensor_type,
            max_bin,
            max_adu,
            has_cooler,
            pixel_size_x,
            pixel_size_y,
            bayer_offset_x,
            bayer_offset_y,
            gain_min,
            gain_max,
            gain,
        })
    }

    pub fn disconnect(&self) -> Result<(), CameraError> {
        self.put("connected", &[("Connected", "false")])
    }

    pub fn set_binning(&self, bin: u8) -> Result<(), CameraError> {
        let val = bin.to_string();
        self.put("binx", &[("BinX", &val)])?;
        self.put("biny", &[("BinY", &val)])?;

        // Reset ROI to full frame for the new binning.
        // ASCOM requires NumX/NumY to be set in binned pixels.
        let width = self.get_int("cameraxsize").unwrap_or(0) as u32;
        let height = self.get_int("cameraysize").unwrap_or(0) as u32;
        let num_x = (width / bin as u32).to_string();
        let num_y = (height / bin as u32).to_string();
        self.put("startx", &[("StartX", "0")])?;
        self.put("starty", &[("StartY", "0")])?;
        self.put("numx", &[("NumX", &num_x)])?;
        self.put("numy", &[("NumY", &num_y)])
    }

    pub fn set_gain(&self, gain: i32) -> Result<(), CameraError> {
        let val = gain.to_string();
        self.put("gain", &[("Gain", &val)])
    }

    pub fn start_exposure(&self, duration_secs: f64) -> Result<(), CameraError> {
        let dur = duration_secs.to_string();
        self.put("startexposure", &[("Duration", &dur), ("Light", "true")])
    }

    pub fn is_image_ready(&self) -> Result<bool, CameraError> {
        self.get_bool("imageready")
    }

    pub fn camera_state(&self) -> Result<u8, CameraError> {
        self.get_int("camerastate").map(|v| v as u8)
    }

    /// Download image using binary ImageBytes format.
    /// Returns raw pixel data (16-bit little-endian) with the 44-byte header stripped.
    pub fn download_image_bytes(&self) -> Result<Vec<u8>, CameraError> {
        let url = format!(
            "{}/imagearray?ClientID={}&ClientTransactionID={}",
            self.base_url,
            self.client_id,
            self.next_tid()
        );

        let resp = self
            .agent
            .get(&url)
            .header("Accept", "application/imagebytes")
            .call()
            .map_err(|e| {
                eprintln!("[AlpacaCamera] Image download failed: {}", e);
                CameraError::CommunicationError
            })?;

        let content_type = resp
            .headers()
            .get("Content-Type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();

        let mut body = resp.into_body();
        // Default read_to_vec() limit is 10MB; camera images can be 16+MB
        let data = body
            .with_config()
            .limit(50 * 1024 * 1024) // 50MB
            .read_to_vec()
            .map_err(|e| {
                eprintln!("[AlpacaCamera] Body read failed: {}", e);
                CameraError::CommunicationError
            })?;

        if content_type.contains("application/imagebytes") {
            // ImageBytes format: 44-byte header + raw pixel data
            // Header layout (all little-endian i32):
            //   0-3:   MetadataVersion
            //   4-7:   ErrorNumber
            //   8-11:  ClientTransactionID
            //   12-15: ServerTransactionID
            //   16-19: DataStart
            //   20-23: ImageElementType
            //   24-27: TransmissionElementType
            //   28-31: Rank
            //   32-35: Dimension1 (NumX / width)
            //   36-39: Dimension2 (NumY / height)
            //   40-43: Dimension3 (planes, if Rank=3)
            if data.len() < 44 {
                return Err(CameraError::InvalidResponse);
            }

            // Check error number (bytes 4-7)
            let error_num =
                i32::from_le_bytes([data[4], data[5], data[6], data[7]]);
            if error_num != 0 {
                eprintln!("[AlpacaCamera] ImageBytes error: {}", error_num);
                return Err(CameraError::CommandRejected);
            }

            let data_start =
                i32::from_le_bytes([data[16], data[17], data[18], data[19]]) as usize;
            let tx_elem_type =
                i32::from_le_bytes([data[24], data[25], data[26], data[27]]);
            let rank =
                i32::from_le_bytes([data[28], data[29], data[30], data[31]]);
            let dim1 =
                i32::from_le_bytes([data[32], data[33], data[34], data[35]]) as usize;
            let dim2 =
                i32::from_le_bytes([data[36], data[37], data[38], data[39]]) as usize;

            // Bytes per pixel from TransmissionElementType
            let bpp: usize = match tx_elem_type {
                1 | 8 => 2,  // Int16 / UInt16
                2 | 4 => 4,  // Int32 / Single
                3 | 5 | 7 => 8,  // Double / UInt64 / Int64
                6 => 1,      // Byte
                _ => 2,      // default to 16-bit
            };

            eprintln!(
                "[AlpacaCamera] ImageBytes: rank={}, dim1={}, dim2={}, bpp={}, data_start={}, total={}",
                rank, dim1, dim2, bpp, data_start, data.len()
            );

            if data_start > data.len() {
                return Err(CameraError::InvalidResponse);
            }

            let pixels = &data[data_start..];

            // ASCOM ImageArray is [NumX, NumY] stored in .NET row-major order
            // (last index Y varies fastest), which is column-major for the image.
            // We need to transpose to image row-major order (X varies fastest per row).
            if rank == 2 && dim1 > 0 && dim2 > 0 {
                let width = dim1;   // NumX (columns)
                let height = dim2;  // NumY (rows)
                let expected = width * height * bpp;

                if pixels.len() >= expected {
                    let mut row_major = vec![0u8; expected];
                    // Column-major: pixel(x,y) at offset (x * height + y) * bpp
                    // Row-major:    pixel(x,y) at offset (y * width + x) * bpp
                    for x in 0..width {
                        let src_col = x * height * bpp;
                        for y in 0..height {
                            let src = src_col + y * bpp;
                            let dst = (y * width + x) * bpp;
                            row_major[dst..dst + bpp]
                                .copy_from_slice(&pixels[src..src + bpp]);
                        }
                    }
                    Ok(row_major)
                } else {
                    eprintln!(
                        "[AlpacaCamera] Pixel data too short: {} < {}",
                        pixels.len(),
                        expected
                    );
                    Ok(pixels.to_vec())
                }
            } else {
                // Rank != 2 or unknown dimensions — return as-is
                Ok(pixels.to_vec())
            }
        } else {
            // Fallback: JSON response — shouldn't happen since we request ImageBytes
            Err(CameraError::InvalidResponse)
        }
    }

    pub fn get_temperature(&self) -> Result<f64, CameraError> {
        self.get_float("ccdtemperature")
    }

    pub fn set_cooler(&self, enabled: bool, target_celsius: f64) -> Result<(), CameraError> {
        let val = if enabled { "true" } else { "false" };
        self.put("cooleron", &[("CoolerOn", val)])?;
        if enabled {
            let temp = target_celsius.to_string();
            self.put("setccdtemperature", &[("SetCCDTemperature", &temp)])?;
        }
        Ok(())
    }

    pub fn abort_exposure(&self) -> Result<(), CameraError> {
        self.put("abortexposure", &[])
    }
}

// --- JSON helpers (same pattern as mount/alpaca.rs) ---

fn extract_json_value(json: &str) -> Result<String, CameraError> {
    let key = "\"Value\"";
    let pos = json.find(key).ok_or(CameraError::InvalidResponse)?;
    let rest = &json[pos + key.len()..];
    let rest = rest.trim_start();
    let rest = rest.strip_prefix(':').ok_or(CameraError::InvalidResponse)?;
    let rest = rest.trim_start();

    if rest.starts_with('"') {
        let end = rest[1..].find('"').ok_or(CameraError::InvalidResponse)?;
        Ok(rest[1..1 + end].to_string())
    } else {
        let end = rest
            .find(|c: char| c == ',' || c == '}' || c == ']' || c.is_whitespace())
            .unwrap_or(rest.len());
        Ok(rest[..end].to_string())
    }
}

fn check_alpaca_error(json: &str) -> Result<(), CameraError> {
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
                eprintln!("[AlpacaCamera] Error {num}: {msg}");
                return Err(CameraError::CommandRejected);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_json_value() {
        let json = r#"{"Value": 3840, "ErrorNumber": 0}"#;
        assert_eq!(extract_json_value(json).unwrap(), "3840");
    }

    #[test]
    fn test_extract_bool_value() {
        let json = r#"{"Value": true, "ErrorNumber": 0}"#;
        assert_eq!(extract_json_value(json).unwrap(), "true");
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
