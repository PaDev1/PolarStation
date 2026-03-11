//! Mount control with pluggable protocol backends.
//!
//! Supported backends:
//! - ASCOM Alpaca (HTTP REST) — Wi-Fi/Ethernet
//! - LX200 serial — USB/serial, used by AM5 and many others
//! - ZWO ASI Mount (planned) — direct USB control via ZWO SDK
//!
//! New backends implement the `MountBackend` trait.

use std::sync::Mutex;
use std::time::Duration;

use crate::coordinates::MountStatus;

pub mod alpaca;
pub mod lx200;

/// Errors from mount operations.
#[derive(Debug, thiserror::Error)]
pub enum MountError {
    #[error("Not connected to mount")]
    NotConnected,
    #[error("Connection failed")]
    ConnectionFailed,
    #[error("Communication error")]
    CommunicationError,
    #[error("Mount rejected command")]
    CommandRejected,
    #[error("Invalid response from mount")]
    InvalidResponse,
    #[error("Timeout waiting for mount response")]
    Timeout,
}

/// Tracking rate for sidereal, lunar, solar, or King tracking.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackingRate {
    Sidereal = 0,
    Lunar = 1,
    Solar = 2,
    King = 3,
}

impl TrackingRate {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Lunar,
            2 => Self::Solar,
            3 => Self::King,
            _ => Self::Sidereal,
        }
    }
}

/// Trait for mount protocol backends.
///
/// Implement this trait to add support for a new mount protocol.
/// All methods take `&mut self` since serial/network I/O is stateful.
pub trait MountBackendTrait: Send {
    fn get_status(&mut self) -> Result<MountStatus, MountError>;
    fn slew_ra_degrees(&mut self, degrees: f64) -> Result<(), MountError>;
    fn set_tracking(&mut self, enabled: bool) -> Result<(), MountError>;
    fn abort(&mut self) -> Result<(), MountError>;
    fn disconnect(&mut self) -> Result<(), MountError> {
        Ok(()) // Default no-op; backends can override
    }
    fn backend_name(&self) -> &str;

    /// GoTo a specific RA/Dec position (J2000).
    fn goto_radec(&mut self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError>;

    /// Set the tracking rate.
    fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), MountError>;

    /// Move an axis at a given rate (degrees/second). 0 = stop.
    /// axis: 0 = RA/Az, 1 = Dec/Alt.
    fn move_axis(&mut self, axis: u8, rate_deg_per_sec: f64) -> Result<(), MountError>;

    /// Park the mount. Default: not supported.
    fn park(&mut self) -> Result<(), MountError> {
        Err(MountError::CommandRejected)
    }

    /// Unpark the mount. Default: not supported.
    fn unpark(&mut self) -> Result<(), MountError> {
        Err(MountError::CommandRejected)
    }
}

/// Mount controller exposed to Swift via UniFFI.
///
/// Protocol-agnostic: delegates to whichever `MountBackendTrait` is connected.
/// Thread-safe via Mutex.
pub struct MountController {
    backend: Mutex<Option<Box<dyn MountBackendTrait>>>,
}

impl MountController {
    pub fn new() -> Self {
        Self {
            backend: Mutex::new(None),
        }
    }

    /// Connect to an ASCOM Alpaca mount over HTTP.
    pub fn connect_alpaca(&self, host: String, port: u32) -> Result<(), MountError> {
        let client = alpaca::AlpacaClient::new(&host, port as u16)?;
        client.set_connected_flag(true)?;
        let mut guard = self.backend.lock().unwrap();
        *guard = Some(Box::new(client));
        Ok(())
    }

    /// Connect to a mount via LX200 serial protocol (AM5, etc.).
    pub fn connect_lx200(&self, device_path: String, baud_rate: u32) -> Result<(), MountError> {
        let client = lx200::Lx200Client::new(&device_path, baud_rate)?;
        let mut guard = self.backend.lock().unwrap();
        *guard = Some(Box::new(client));
        Ok(())
    }

    /// Connect to a mount via LX200 protocol over TCP/WiFi.
    /// AM5 default: host="192.168.4.1", port=4030.
    pub fn connect_lx200_tcp(&self, host: String, port: u32) -> Result<(), MountError> {
        let client = lx200::Lx200Client::new_tcp(&host, port as u16)?;
        let mut guard = self.backend.lock().unwrap();
        *guard = Some(Box::new(client));
        Ok(())
    }

    /// Disconnect from the mount.
    pub fn disconnect(&self) -> Result<(), MountError> {
        let mut guard = self.backend.lock().unwrap();
        if let Some(ref mut backend) = *guard {
            let _ = backend.disconnect();
        }
        *guard = None;
        Ok(())
    }

    /// Check if connected.
    pub fn is_connected(&self) -> bool {
        self.backend.lock().unwrap().is_some()
    }

    /// Name of the currently connected backend (e.g. "Alpaca", "LX200").
    pub fn backend_name(&self) -> Option<String> {
        self.backend.lock().unwrap().as_ref().map(|b| b.backend_name().to_string())
    }

    /// Get current mount status (position, tracking, slewing).
    pub fn get_status(&self) -> Result<MountStatus, MountError> {
        let mut guard = self.backend.lock().unwrap();
        match guard.as_mut() {
            Some(backend) => backend.get_status(),
            None => Err(MountError::NotConnected),
        }
    }

    /// Get current RA in hours.
    pub fn get_ra_hours(&self) -> Result<f64, MountError> {
        Ok(self.get_status()?.ra_hours)
    }

    /// Get current Dec in degrees.
    pub fn get_dec_deg(&self) -> Result<f64, MountError> {
        Ok(self.get_status()?.dec_deg)
    }

    /// Slew the RA axis by the given number of degrees.
    /// Positive = east (increasing RA), negative = west.
    pub fn slew_ra_degrees(&self, degrees: f64) -> Result<(), MountError> {
        let mut guard = self.backend.lock().unwrap();
        match guard.as_mut() {
            Some(backend) => backend.slew_ra_degrees(degrees),
            None => Err(MountError::NotConnected),
        }
    }

    /// Start or stop sidereal tracking.
    pub fn set_tracking(&self, enabled: bool) -> Result<(), MountError> {
        let mut guard = self.backend.lock().unwrap();
        match guard.as_mut() {
            Some(backend) => backend.set_tracking(enabled),
            None => Err(MountError::NotConnected),
        }
    }

    /// Emergency stop all motion.
    pub fn abort(&self) -> Result<(), MountError> {
        let mut guard = self.backend.lock().unwrap();
        match guard.as_mut() {
            Some(backend) => backend.abort(),
            None => Err(MountError::NotConnected),
        }
    }

    /// GoTo a specific RA/Dec (J2000). Non-blocking: starts slew, returns immediately.
    pub fn goto_radec(&self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        let mut guard = self.backend.lock().unwrap();
        match guard.as_mut() {
            Some(backend) => backend.goto_radec(ra_hours, dec_deg),
            None => Err(MountError::NotConnected),
        }
    }

    /// Set tracking rate (0=sidereal, 1=lunar, 2=solar, 3=king).
    pub fn set_tracking_rate(&self, rate: u8) -> Result<(), MountError> {
        let mut guard = self.backend.lock().unwrap();
        match guard.as_mut() {
            Some(backend) => backend.set_tracking_rate(TrackingRate::from_u8(rate)),
            None => Err(MountError::NotConnected),
        }
    }

    /// Move an axis at a given rate (degrees/second). 0 = stop.
    /// axis: 0 = RA/Az, 1 = Dec/Alt.
    pub fn move_axis(&self, axis: u8, rate_deg_per_sec: f64) -> Result<(), MountError> {
        let mut guard = self.backend.lock().unwrap();
        match guard.as_mut() {
            Some(backend) => backend.move_axis(axis, rate_deg_per_sec),
            None => Err(MountError::NotConnected),
        }
    }

    /// Park the mount.
    pub fn park(&self) -> Result<(), MountError> {
        let mut guard = self.backend.lock().unwrap();
        match guard.as_mut() {
            Some(backend) => backend.park(),
            None => Err(MountError::NotConnected),
        }
    }

    /// Unpark the mount.
    pub fn unpark(&self) -> Result<(), MountError> {
        let mut guard = self.backend.lock().unwrap();
        match guard.as_mut() {
            Some(backend) => backend.unpark(),
            None => Err(MountError::NotConnected),
        }
    }

    /// Discover Alpaca devices on the local network via UDP broadcast.
    /// Returns a list of "host:port" strings.
    pub fn discover_alpaca(timeout_ms: u32) -> Vec<String> {
        alpaca::discover(Duration::from_millis(timeout_ms as u64))
    }

    /// List available serial ports (for LX200/ASI USB connections).
    pub fn list_serial_ports() -> Vec<String> {
        serialport::available_ports()
            .unwrap_or_default()
            .iter()
            .map(|p| p.port_name.clone())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mount_not_connected() {
        let mc = MountController::new();
        assert!(!mc.is_connected());
        assert!(mc.backend_name().is_none());
        assert!(matches!(mc.get_status(), Err(MountError::NotConnected)));
    }

    #[test]
    fn test_disconnect_when_not_connected() {
        let mc = MountController::new();
        assert!(mc.disconnect().is_ok());
    }

    #[test]
    fn test_list_serial_ports() {
        // Just verify it doesn't crash
        let ports = MountController::list_serial_ports();
        // May be empty in CI/test environments
        let _ = ports;
    }

    #[test]
    fn test_new_methods_not_connected() {
        let mc = MountController::new();
        assert!(matches!(mc.goto_radec(12.0, 45.0), Err(MountError::NotConnected)));
        assert!(matches!(mc.set_tracking_rate(0), Err(MountError::NotConnected)));
        assert!(matches!(mc.move_axis(0, 1.0), Err(MountError::NotConnected)));
        assert!(matches!(mc.park(), Err(MountError::NotConnected)));
        assert!(matches!(mc.unpark(), Err(MountError::NotConnected)));
    }

    #[test]
    fn test_tracking_rate_from_u8() {
        assert_eq!(TrackingRate::from_u8(0), TrackingRate::Sidereal);
        assert_eq!(TrackingRate::from_u8(1), TrackingRate::Lunar);
        assert_eq!(TrackingRate::from_u8(2), TrackingRate::Solar);
        assert_eq!(TrackingRate::from_u8(3), TrackingRate::King);
        assert_eq!(TrackingRate::from_u8(99), TrackingRate::Sidereal); // fallback
    }

    // ── Hardware integration tests (run with: cargo test -- --ignored) ──

    /// Detect the USB serial port for the mount.
    fn find_usb_mount_port() -> Option<String> {
        MountController::list_serial_ports()
            .into_iter()
            .find(|p| p.contains("usbmodem") || p.contains("usbserial"))
    }

    /// Try each baud rate, send :GR# raw, print what comes back.
    #[test]
    #[ignore]
    fn test_raw_serial_diagnostic() {
        use std::io::{Read, Write};
        let port_name = find_usb_mount_port().expect("No USB serial port found");

        for baud in [9600u32, 115200] {
            println!("\n=== Baud {} ===", baud);
            let mut port = match serialport::new(&port_name, baud)
                .timeout(Duration::from_millis(2000))
                .open()
            {
                Ok(p) => p,
                Err(e) => { println!("Open failed: {e}"); continue; }
            };

            // Flush stale data (tcflush equivalent)
            let _ = port.clear(serialport::ClearBuffer::All);
            std::thread::sleep(Duration::from_millis(100));
            let _ = port.clear(serialport::ClearBuffer::All);

            // Send :GR# and read byte-by-byte
            let cmd = b":GR#";
            println!("  Sending: {:?}", std::str::from_utf8(cmd).unwrap());
            port.write_all(cmd).expect("write");
            port.flush().expect("flush");

            let start = std::time::Instant::now();
            let mut response = Vec::new();
            let mut buf = [0u8; 1];
            loop {
                if start.elapsed() > Duration::from_secs(3) {
                    println!("  TIMEOUT after 3s, got {} bytes", response.len());
                    break;
                }
                match port.read(&mut buf) {
                    Ok(1) => {
                        response.push(buf[0]);
                        print!("  [{:02x} '{}'] ", buf[0], if buf[0].is_ascii_graphic() || buf[0] == b' ' { buf[0] as char } else { '.' });
                        if buf[0] == b'#' {
                            println!("\n  COMPLETE in {:?}: {:?}", start.elapsed(),
                                     String::from_utf8_lossy(&response));
                            break;
                        }
                    }
                    Ok(_) => {}
                    Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => {
                        println!("  (timeout on read, {} bytes so far)", response.len());
                        break;
                    }
                    Err(e) => {
                        println!("  Read error: {e}");
                        break;
                    }
                }
            }

            // Also try :GD# and :GU#
            for cmd in [":GD#", ":GU#"] {
                let _ = port.clear(serialport::ClearBuffer::All);
                port.write_all(cmd.as_bytes()).expect("write");
                port.flush().expect("flush");

                let start = std::time::Instant::now();
                let mut resp = Vec::new();
                loop {
                    if start.elapsed() > Duration::from_secs(3) { break; }
                    match port.read(&mut buf) {
                        Ok(1) => {
                            resp.push(buf[0]);
                            if buf[0] == b'#' { break; }
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => break,
                        _ => break,
                    }
                }
                println!("  {cmd} -> {:?} ({:?})", String::from_utf8_lossy(&resp), start.elapsed());
            }

            drop(port);
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    /// Raw command diagnostic: send each command and print full response.
    #[test]
    #[ignore]
    fn test_lx200_command_diagnostic() {
        use std::io::{Read, Write};
        let port_name = find_usb_mount_port().expect("No USB serial port found");
        let mut port = serialport::new(&port_name, 9600)
            .timeout(Duration::from_millis(500))
            .open()
            .expect("Failed to open serial port");

        let _ = port.clear(serialport::ClearBuffer::All);
        std::thread::sleep(Duration::from_millis(100));

        /// Send a command, read until '#' or timeout, print result.
        fn send(port: &mut Box<dyn serialport::SerialPort>, cmd: &str) -> String {
            let _ = port.clear(serialport::ClearBuffer::All);
            port.write_all(cmd.as_bytes()).expect("write");
            port.flush().expect("flush");

            let start = std::time::Instant::now();
            let mut resp = Vec::new();
            let mut buf = [0u8; 1];
            while start.elapsed() < Duration::from_millis(2000) {
                match port.read(&mut buf) {
                    Ok(1) => {
                        resp.push(buf[0]);
                        if buf[0] == b'#' { break; }
                    }
                    Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => {
                        if !resp.is_empty() { break; }  // got some data, timeout = done
                        continue;
                    }
                    _ => break,
                }
            }
            let s = String::from_utf8_lossy(&resp).to_string();
            let dt = start.elapsed();
            if resp.is_empty() {
                println!("  {cmd:12} -> (no response) [{dt:?}]");
            } else {
                println!("  {cmd:12} -> {:?} (raw: {:02x?}) [{dt:?}]", s, resp);
            }
            s
        }

        println!("=== Status commands ===");
        send(&mut port, ":GR#");    // Get RA
        send(&mut port, ":GD#");    // Get Dec
        send(&mut port, ":GU#");    // Get AM5 status flags
        send(&mut port, ":GAT#");   // Get tracking state (AM5: '1' or '0')
        send(&mut port, ":GT#");    // Get tracking mode

        println!("\n=== Enable tracking ===");
        send(&mut port, ":Te#");    // Track enable (AM5 specific)

        println!("\n=== Status after tracking enable ===");
        send(&mut port, ":GU#");
        send(&mut port, ":GAT#");

        println!("\n=== Set slew rate and move East ===");
        send(&mut port, ":R2#");    // Set rate index 2 (1x sidereal)
        send(&mut port, ":Me#");    // Move East

        // Record RA before
        let ra_before = send(&mut port, ":GR#");
        println!("  (waiting 2 seconds...)");
        std::thread::sleep(Duration::from_secs(2));
        let ra_after = send(&mut port, ":GR#");
        println!("  RA before={ra_before:?}, after={ra_after:?}");

        println!("\n=== Stop East ===");
        send(&mut port, ":Qe#");    // Stop East
        send(&mut port, ":Qw#");    // Stop West (belt and suspenders)

        println!("\n=== Move with higher rate ===");
        send(&mut port, ":R9#");    // Max rate (1440x)
        send(&mut port, ":Me#");    // Move East
        let ra_before = send(&mut port, ":GR#");
        println!("  (waiting 2 seconds at 1440x...)");
        std::thread::sleep(Duration::from_secs(2));
        let ra_after = send(&mut port, ":GR#");
        println!("  RA before={ra_before:?}, after={ra_after:?}");

        println!("\n=== Stop all ===");
        send(&mut port, ":Q#");     // Emergency stop

        println!("\n=== Disable tracking ===");
        send(&mut port, ":Td#");    // Track disable

        println!("\n=== Final status ===");
        send(&mut port, ":GU#");
        send(&mut port, ":GR#");
        send(&mut port, ":GD#");

        println!("\nDone.");
    }
}
