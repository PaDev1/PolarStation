//! LX200 serial/TCP protocol client.
//!
//! Compatible with ZWO AM5/AM3 and other LX200-speaking mounts.
//! Reference: INDI lx200am5.cpp driver by Jasem Mutlaq.
//!
//! Connections:
//! - USB serial: /dev/cu.usbmodemXXXX (CDC-ACM)
//! - TCP/WiFi:   192.168.4.1:4030 (AM5 default)

use std::io::{Read, Write};
use std::time::Duration;

use crate::coordinates::MountStatus;
use super::{MountError, TrackingRate};

/// Append a line to /tmp/polar_mount.log for debugging.
fn mount_log(msg: &str) {
    use std::fs::OpenOptions;
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open("/tmp/polar_mount.log") {
        let _ = writeln!(f, "[{}] {}", chrono_now(), msg);
    }
    eprintln!("{}", msg);
}

/// Simple local timestamp (UTC+2 for Finland).
fn chrono_now() -> String {
    let dur = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = dur.as_secs() + 2 * 3600; // UTC+2
    let h = (secs % 86400) / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    format!("{:02}:{:02}:{:02}", h, m, s)
}

/// Abstract transport: serial port or TCP socket.
trait Transport: Read + Write + Send {
    fn clear_buffers(&mut self) -> Result<(), MountError>;
    fn drain(&mut self) -> Result<(), MountError>;
    #[allow(dead_code)]
    fn transport_name(&self) -> &str;
}

/// Serial port transport.
struct SerialTransport {
    port: Box<dyn serialport::SerialPort>,
}

impl Read for SerialTransport {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.port.read(buf)
    }
}

impl Write for SerialTransport {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.port.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.port.flush()
    }
}

impl Transport for SerialTransport {
    fn clear_buffers(&mut self) -> Result<(), MountError> {
        self.port.clear(serialport::ClearBuffer::All)
            .map_err(|_| MountError::CommunicationError)
    }
    fn drain(&mut self) -> Result<(), MountError> {
        self.port.flush().map_err(|_| MountError::CommunicationError)
    }
    fn transport_name(&self) -> &str {
        "Serial"
    }
}

/// TCP socket transport for WiFi-connected mounts.
struct TcpTransport {
    stream: std::net::TcpStream,
}

impl Read for TcpTransport {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.stream.read(buf)
    }
}

impl Write for TcpTransport {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.stream.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.stream.flush()
    }
}

impl Transport for TcpTransport {
    fn clear_buffers(&mut self) -> Result<(), MountError> {
        // TCP has no equivalent of tcflush; drain any pending input
        self.stream.set_nonblocking(true).ok();
        let mut drain = [0u8; 256];
        while let Ok(n) = self.stream.read(&mut drain) {
            if n == 0 { break; }
        }
        self.stream.set_nonblocking(false).ok();
        Ok(())
    }
    fn drain(&mut self) -> Result<(), MountError> {
        self.stream.flush().map_err(|_| MountError::CommunicationError)
    }
    fn transport_name(&self) -> &str {
        "TCP"
    }
}

/// LX200 protocol client (serial or TCP).
pub struct Lx200Client {
    transport: Box<dyn Transport>,
}

impl Lx200Client {
    /// Connect via serial port.
    pub fn new(device_path: &str, baud_rate: u32) -> Result<Self, MountError> {
        let port = serialport::new(device_path, baud_rate)
            .timeout(Duration::from_secs(3))
            .open()
            .map_err(|_| MountError::ConnectionFailed)?;

        let mut client = Self {
            transport: Box::new(SerialTransport { port }),
        };

        // Flush any stale data, like INDI does
        client.transport.clear_buffers()?;
        std::thread::sleep(Duration::from_millis(100));
        client.transport.clear_buffers()?;

        // Verify connection by reading RA (same as INDI checkConnection)
        for attempt in 0..2 {
            match client.command(":GR#") {
                Ok(_) => return Ok(client),
                Err(_) if attempt == 0 => {
                    std::thread::sleep(Duration::from_millis(250));
                }
                Err(_) => {}
            }
        }
        Err(MountError::ConnectionFailed)
    }

    /// Connect via TCP (WiFi). AM5 default: host="192.168.4.1", port=4030.
    pub fn new_tcp(host: &str, port: u16) -> Result<Self, MountError> {
        let addr = format!("{}:{}", host, port);
        let stream = std::net::TcpStream::connect_timeout(
            &addr.parse().map_err(|_| MountError::ConnectionFailed)?,
            Duration::from_secs(5),
        ).map_err(|_| MountError::ConnectionFailed)?;

        stream.set_read_timeout(Some(Duration::from_secs(3)))
            .map_err(|_| MountError::ConnectionFailed)?;
        stream.set_write_timeout(Some(Duration::from_secs(3)))
            .map_err(|_| MountError::ConnectionFailed)?;

        let mut client = Self {
            transport: Box::new(TcpTransport { stream }),
        };

        // Verify connection (same as INDI checkConnection)
        for attempt in 0..2 {
            match client.command(":GR#") {
                Ok(_) => return Ok(client),
                Err(_) if attempt == 0 => {
                    std::thread::sleep(Duration::from_millis(250));
                }
                Err(_) => {}
            }
        }
        Err(MountError::ConnectionFailed)
    }

    /// Send a command and read response until '#' terminator.
    /// Flushes buffers before sending, exactly like INDI's sendCommand().
    fn command(&mut self, cmd: &str) -> Result<String, MountError> {
        // tcflush equivalent — clear stale data before sending
        self.transport.clear_buffers()?;

        self.transport.write_all(cmd.as_bytes())
            .map_err(|_| MountError::CommunicationError)?;
        self.transport.flush()
            .map_err(|_| MountError::CommunicationError)?;

        let mut response = String::new();
        let mut buf = [0u8; 1];
        let deadline = std::time::Instant::now() + Duration::from_secs(3);

        while std::time::Instant::now() < deadline {
            match self.transport.read(&mut buf) {
                Ok(1) => {
                    let ch = buf[0] as char;
                    if ch == '#' {
                        return Ok(response);
                    }
                    response.push(ch);
                }
                Ok(_) => {}
                Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => continue,
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(_) => return Err(MountError::CommunicationError),
            }
        }
        Err(MountError::Timeout)
    }

    /// Send a command and read a fixed number of response bytes (no '#' terminator).
    fn command_fixed(&mut self, cmd: &str, len: usize) -> Result<String, MountError> {
        self.transport.clear_buffers()?;

        self.transport.write_all(cmd.as_bytes())
            .map_err(|_| MountError::CommunicationError)?;
        self.transport.flush()
            .map_err(|_| MountError::CommunicationError)?;

        let mut response = vec![0u8; len];
        let mut total = 0;
        let deadline = std::time::Instant::now() + Duration::from_secs(3);

        while total < len && std::time::Instant::now() < deadline {
            match self.transport.read(&mut response[total..]) {
                Ok(n) => total += n,
                Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => continue,
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(_) => return Err(MountError::CommunicationError),
            }
        }
        if total < len {
            return Err(MountError::Timeout);
        }
        String::from_utf8(response).map_err(|_| MountError::InvalidResponse)
    }

    /// Send a command with no response expected. Uses tcdrain like INDI.
    fn command_blind(&mut self, cmd: &str) -> Result<(), MountError> {
        self.transport.clear_buffers()?;
        self.transport.write_all(cmd.as_bytes())
            .map_err(|_| MountError::CommunicationError)?;
        self.transport.drain()
    }

    /// Parse LX200 RA string "HH:MM:SS" or "HH:MM.M" to decimal hours.
    fn parse_ra(s: &str) -> Result<f64, MountError> {
        let parts: Vec<&str> = s.split(':').collect();
        if parts.len() < 2 {
            return Err(MountError::InvalidResponse);
        }
        let hours: f64 = parts[0].parse().map_err(|_| MountError::InvalidResponse)?;
        let minutes: f64 = parts[1].parse().map_err(|_| MountError::InvalidResponse)?;
        let seconds: f64 = if parts.len() > 2 {
            parts[2].parse().unwrap_or(0.0)
        } else {
            0.0
        };
        Ok(hours + minutes / 60.0 + seconds / 3600.0)
    }

    /// Parse LX200 azimuth string "DDD*MM:SS" or "DDD*MM" to decimal degrees (0-360).
    fn parse_az(s: &str) -> Result<f64, MountError> {
        let s = s.replace(['*', '\u{00b0}', '\u{00df}', '\''], ":");
        let parts: Vec<&str> = s.split(':').collect();
        if parts.len() < 2 {
            return Err(MountError::InvalidResponse);
        }
        let deg: f64 = parts[0].parse().map_err(|_| MountError::InvalidResponse)?;
        let min: f64 = parts[1].parse().map_err(|_| MountError::InvalidResponse)?;
        let sec: f64 = if parts.len() > 2 {
            parts[2].parse().unwrap_or(0.0)
        } else {
            0.0
        };
        Ok(deg + min / 60.0 + sec / 3600.0)
    }

    /// Parse LX200 Dec string "+DD*MM:SS" or "+DD*MM" to decimal degrees.
    fn parse_dec(s: &str) -> Result<f64, MountError> {
        let s = s.replace(['*', '\u{00b0}', '\u{00df}'], ":");
        let (sign, rest) = if s.starts_with('-') {
            (-1.0, &s[1..])
        } else if s.starts_with('+') {
            (1.0, &s[1..])
        } else {
            (1.0, s.as_str())
        };

        let parts: Vec<&str> = rest.split(':').collect();
        if parts.len() < 2 {
            return Err(MountError::InvalidResponse);
        }
        let deg: f64 = parts[0].parse().map_err(|_| MountError::InvalidResponse)?;
        let min: f64 = parts[1].parse().map_err(|_| MountError::InvalidResponse)?;
        let sec: f64 = if parts.len() > 2 {
            parts[2].parse().unwrap_or(0.0)
        } else {
            0.0
        };
        Ok(sign * (deg + min / 60.0 + sec / 3600.0))
    }

    pub fn get_status(&mut self) -> Result<MountStatus, MountError> {
        let ra_str = self.command(":GR#")?;
        let dec_str = self.command(":GD#")?;

        let ra_hours = Self::parse_ra(&ra_str)?;
        let dec_deg = Self::parse_dec(&dec_str)?;

        // Query AM5 extended status via :GU# (returns flags like 'N'=not slewing, 'H'=home)
        let mut slewing = false;
        let mut at_park = false;
        let mut tracking = true;
        let mut tracking_rate = 0u8;

        if let Ok(gu) = self.command(":GU#") {
            slewing = !gu.contains('N'); // 'N' = slew complete (not slewing)
            at_park = gu.contains('H');  // 'H' = at home
        }

        // Query tracking state: :GAT# returns '1' if tracking
        if let Ok(gat) = self.command_fixed(":GAT#", 1) {
            tracking = gat == "1";
        }

        // Query tracking mode: :GT# returns '0'-'3'
        if let Ok(gt) = self.command(":GT#") {
            if let Some(ch) = gt.chars().next() {
                tracking_rate = (ch as u8).wrapping_sub(b'0');
                if tracking_rate > 3 { tracking_rate = 0; }
            }
        }

        // Query altitude (:GA#) and azimuth (:GZ#) — standard LX200 commands
        // Format: sDD*MM'SS# (same as Dec)
        let alt_deg = self.command(":GA#").ok()
            .and_then(|s| Self::parse_dec(&s).ok())
            .unwrap_or(f64::NAN);
        let az_deg = self.command(":GZ#").ok()
            .and_then(|s| Self::parse_az(&s).ok())
            .unwrap_or(f64::NAN);

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

    /// Format RA/Dec and initiate GoTo slew.
    /// Matches INDI lx200driver.cpp: setObjectRA + setObjectDEC + Slew.
    /// :Sr and :Sd return 1 byte ('1'=OK), :MS# returns 1 byte ('0'=OK).
    fn set_target_and_slew(&mut self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        mount_log(&format!("[LX200] GoTo: RA={:.4}h Dec={:.4}°", ra_hours, dec_deg));

        // Log full mount state for diagnostics
        if let Ok(gu) = self.command(":GU#") {
            mount_log(&format!("[LX200] :GU# flags: {:?}", gu));
            if gu.contains('n') || gu.contains('H') {
                mount_log("[LX200] Tracking off, enabling before GoTo");
                let _ = self.set_tracking(true);
                std::thread::sleep(Duration::from_millis(200));
            }
        }
        // Set target RA — response is 1 byte: '1'=valid, '0'=invalid
        let ra_h = ra_hours as u32;
        let ra_m = ((ra_hours - ra_h as f64) * 60.0) as u32;
        let ra_s = ((ra_hours - ra_h as f64 - ra_m as f64 / 60.0) * 3600.0) as u32;
        let cmd = format!(":Sr {:02}:{:02}:{:02}#", ra_h, ra_m, ra_s);
        mount_log(&format!("[LX200] Sending: {}", cmd));
        let resp = self.command_fixed(&cmd, 1)?;
        mount_log(&format!("[LX200] :Sr response: {:?}", resp));
        if resp != "1" {
            mount_log(&format!("[LX200] ERROR: :Sr rejected (response={:?})", resp));
            return Err(MountError::CommandRejected);
        }

        // Set target Dec — response is 1 byte: '1'=valid, '0'=invalid
        let dec_sign = if dec_deg >= 0.0 { '+' } else { '-' };
        let dec_abs = dec_deg.abs();
        let dec_d = dec_abs as u32;
        let dec_m = ((dec_abs - dec_d as f64) * 60.0) as u32;
        let dec_s = ((dec_abs - dec_d as f64 - dec_m as f64 / 60.0) * 3600.0) as u32;
        let cmd = format!(":Sd {}{:02}*{:02}:{:02}#", dec_sign, dec_d, dec_m, dec_s);
        mount_log(&format!("[LX200] Sending: {}", cmd));
        let resp = self.command_fixed(&cmd, 1)?;
        mount_log(&format!("[LX200] :Sd response: {:?}", resp));
        if resp != "1" {
            mount_log(&format!("[LX200] ERROR: :Sd rejected (response={:?})", resp));
            return Err(MountError::CommandRejected);
        }

        // Initiate slew — first byte: '0'=OK, anything else=error
        // On error, AM5/OnStep may send additional message followed by '#'
        mount_log("[LX200] Sending: :MS#");
        let resp = self.command_fixed(":MS#", 1)?;
        mount_log(&format!("[LX200] :MS response byte: {:?}", resp));
        if resp != "0" {
            // Try to read error message (OnStep sends 'E<n><msg>#')
            let mut err_detail = resp.clone();
            // Read remaining bytes until '#' without sending anything
            let mut buf = [0u8; 1];
            let deadline = std::time::Instant::now() + Duration::from_millis(500);
            while std::time::Instant::now() < deadline {
                match self.transport.read(&mut buf) {
                    Ok(1) if buf[0] == b'#' => break,
                    Ok(1) => err_detail.push(buf[0] as char),
                    _ => break,
                }
            }
            mount_log(&format!("[LX200] ERROR: :MS rejected: {:?}", err_detail));
            return Err(MountError::CommandRejected);
        }
        mount_log("[LX200] GoTo initiated successfully");
        Ok(())
    }

    pub fn slew_ra_degrees(&mut self, degrees: f64) -> Result<(), MountError> {
        let ra_str = self.command(":GR#")?;
        let dec_str = self.command(":GD#")?;
        let current_ra = Self::parse_ra(&ra_str)?;
        let current_dec = Self::parse_dec(&dec_str)?;
        let target_ra = (current_ra + degrees / 15.0).rem_euclid(24.0);
        self.set_target_and_slew(target_ra, current_dec)
    }

    pub fn goto_radec(&mut self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        self.set_target_and_slew(ra_hours, dec_deg)
    }

    /// Sync mount position: tell the mount it is currently pointing at (ra_hours, dec_deg).
    /// Uses :Sr/:Sd to set target, then :CM# to sync (align).
    /// This is needed before GoTo will work — the mount must know its position.
    pub fn sync_position(&mut self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        mount_log(&format!("[LX200] Sync position: RA={:.4}h Dec={:.4}°", ra_hours, dec_deg));

        // Set target RA
        let ra_h = ra_hours as u32;
        let ra_m = ((ra_hours - ra_h as f64) * 60.0) as u32;
        let ra_s = ((ra_hours - ra_h as f64 - ra_m as f64 / 60.0) * 3600.0) as u32;
        let cmd = format!(":Sr {:02}:{:02}:{:02}#", ra_h, ra_m, ra_s);
        let resp = self.command_fixed(&cmd, 1)?;
        if resp != "1" {
            mount_log(&format!("[LX200] ERROR: :Sr rejected for sync (response={:?})", resp));
            return Err(MountError::CommandRejected);
        }

        // Set target Dec
        let dec_sign = if dec_deg >= 0.0 { '+' } else { '-' };
        let dec_abs = dec_deg.abs();
        let dec_d = dec_abs as u32;
        let dec_m = ((dec_abs - dec_d as f64) * 60.0) as u32;
        let dec_s = ((dec_abs - dec_d as f64 - dec_m as f64 / 60.0) * 3600.0) as u32;
        let cmd = format!(":Sd {}{:02}*{:02}:{:02}#", dec_sign, dec_d, dec_m, dec_s);
        let resp = self.command_fixed(&cmd, 1)?;
        if resp != "1" {
            mount_log(&format!("[LX200] ERROR: :Sd rejected for sync (response={:?})", resp));
            return Err(MountError::CommandRejected);
        }

        // Sync: :CM# tells the mount "you are currently pointing at the Sr/Sd target"
        let resp = self.command(":CM#")?;
        mount_log(&format!("[LX200] :CM# sync response: {:?}", resp));
        Ok(())
    }

    /// Enable/disable tracking. AM5 uses :Te#/:Td# (not generic LX200 :TQ#/:TN#).
    pub fn set_tracking(&mut self, enabled: bool) -> Result<(), MountError> {
        // AM5: :Te# to enable, :Td# to disable; returns '1' on success
        let cmd = if enabled { ":Te#" } else { ":Td#" };
        let resp = self.command_fixed(cmd, 1)?;
        if resp != "1" {
            return Err(MountError::CommandRejected);
        }
        Ok(())
    }

    pub fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), MountError> {
        match rate {
            TrackingRate::Sidereal => self.command_blind(":TQ#"),
            TrackingRate::Lunar => self.command_blind(":TL#"),
            TrackingRate::Solar => self.command_blind(":TS#"),
            TrackingRate::King => self.command_blind(":TQ#"), // fallback to sidereal
        }
    }

    /// Move axis at a rate. AM5 uses :R0#-:R9# for slew rate selection.
    /// Automatically enables tracking if mount is at home/parked.
    pub fn move_axis(&mut self, axis: u8, rate_deg_per_sec: f64) -> Result<(), MountError> {
        // AM5 won't move while parked — enable tracking to unpark
        if rate_deg_per_sec.abs() > 1e-6 {
            if let Ok(gu) = self.command(":GU#") {
                if gu.contains('H') {
                    // Mount is at home, enable tracking to unpark
                    let _ = self.set_tracking(true);
                }
            }
        }

        if rate_deg_per_sec.abs() < 1e-6 {
            // Stop all motion on this axis
            if axis == 0 {
                self.command_blind(":Qe#")?;
                self.command_blind(":Qw#")
            } else {
                self.command_blind(":Qn#")?;
                self.command_blind(":Qs#")
            }
        } else {
            // AM5 slew rate indices: 0=0.25x, 1=0.5x, 2=1x, 3=2x, 4=4x,
            // 5=8x, 6=20x, 7=60x, 8=720x, 9=1440x
            // Sidereal rate ≈ 0.00417 deg/s, so rate_deg_per_sec / 0.00417 = multiple
            let sidereal = 0.00417;
            let multiple = rate_deg_per_sec.abs() / sidereal;
            let index = if multiple > 1000.0 { 9 }
                else if multiple > 360.0 { 8 }
                else if multiple > 40.0 { 7 }
                else if multiple > 12.0 { 6 }
                else if multiple > 6.0 { 5 }
                else if multiple > 3.0 { 4 }
                else if multiple > 1.5 { 3 }
                else if multiple > 0.75 { 2 }
                else if multiple > 0.3 { 1 }
                else { 0 };

            let cmd = format!(":R{}#", index);
            self.command_blind(&cmd)?;

            // Start motion in the appropriate direction
            if axis == 0 {
                if rate_deg_per_sec > 0.0 {
                    self.command_blind(":Me#")
                } else {
                    self.command_blind(":Mw#")
                }
            } else {
                if rate_deg_per_sec > 0.0 {
                    self.command_blind(":Mn#")
                } else {
                    self.command_blind(":Ms#")
                }
            }
        }
    }

    /// Sync the mount's internal clock and site location with the computer.
    ///
    /// LX200 commands:
    ///   :SL HH:MM:SS# — set local time
    ///   :SC MM/DD/YY# — set date
    ///   :SG sHH.H#    — set UTC offset (hours behind UTC, negative = east)
    ///   :St sDD*MM#   — set site latitude
    ///   :Sg DDD*MM#   — set site longitude
    pub fn sync_datetime(&mut self, observer_lat_deg: f64, observer_lon_deg: f64, utc_offset_hours: f64) -> Result<(), MountError> {
        mount_log(&format!("[LX200] sync_datetime: lat={:.4} lon={:.4} utcOff={:.1}",
            observer_lat_deg, observer_lon_deg, utc_offset_hours));

        // Get current UTC time
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| MountError::CommunicationError)?;
        let total_secs = now.as_secs();

        // Compute LOCAL seconds since epoch for both time-of-day and date
        let offset_secs = (utc_offset_hours * 3600.0) as i64;
        let local_epoch_secs = total_secs as i64 + offset_secs;

        // Local time of day
        let local_day_secs = local_epoch_secs.rem_euclid(86400) as u32;
        let local_h = local_day_secs / 3600;
        let local_m = (local_day_secs % 3600) / 60;
        let local_s = local_day_secs % 60;

        // Local date (Hinnant algorithm on local days, not UTC days)
        let local_days = local_epoch_secs.div_euclid(86400);
        let z = local_days + 719468;
        let era = z.div_euclid(146097);
        let doe = z.rem_euclid(146097);
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let y = yoe + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        let y = if m <= 2 { y + 1 } else { y };

        mount_log(&format!("[LX200] Setting local time: {:02}:{:02}:{:02}, date: {}-{:02}-{:02}",
            local_h, local_m, local_s, y, m, d));

        // Set UTC offset FIRST — mount needs this for date validation
        let sg_offset = -utc_offset_hours;
        let cmd = if sg_offset.fract().abs() < 0.01 {
            format!(":SG {:+03.0}#", sg_offset)
        } else {
            format!(":SG {:+05.1}#", sg_offset)
        };
        mount_log(&format!("[LX200] Sending: {}", cmd));
        let resp = self.command_fixed(&cmd, 1);
        mount_log(&format!("[LX200] :SG response: {:?}", resp));

        // Set site latitude: :St sDD*MM#
        let lat_sign = if observer_lat_deg >= 0.0 { '+' } else { '-' };
        let lat_abs = observer_lat_deg.abs();
        let lat_d = lat_abs as u32;
        let lat_m = ((lat_abs - lat_d as f64) * 60.0) as u32;
        let cmd = format!(":St {}{:02}*{:02}#", lat_sign, lat_d, lat_m);
        mount_log(&format!("[LX200] Sending: {}", cmd));
        let resp = self.command_fixed(&cmd, 1);
        mount_log(&format!("[LX200] :St response: {:?}", resp));

        // Set site longitude: :Sg DDD*MM#
        let lon_lx = if observer_lon_deg >= 0.0 {
            360.0 - observer_lon_deg
        } else {
            -observer_lon_deg
        };
        let lon_d = lon_lx as u32;
        let lon_m = ((lon_lx - lon_d as f64) * 60.0) as u32;
        let cmd = format!(":Sg {:03}*{:02}#", lon_d, lon_m);
        mount_log(&format!("[LX200] Sending: {}", cmd));
        let resp = self.command_fixed(&cmd, 1);
        mount_log(&format!("[LX200] :Sg response: {:?}", resp));

        // Set local time: :SL HH:MM:SS#
        let cmd = format!(":SL {:02}:{:02}:{:02}#", local_h, local_m, local_s);
        mount_log(&format!("[LX200] Sending: {}", cmd));
        let resp = self.command_fixed(&cmd, 1);
        mount_log(&format!("[LX200] :SL response: {:?}", resp));
        std::thread::sleep(Duration::from_millis(100));

        // Set date: :SC MM/DD/YY#
        // OnStep responds: 1 byte ('1'=ok, '0'=fail), then on success two '#'-terminated strings.
        self.transport.clear_buffers()?;
        let yy = (y % 100) as u32;
        let mm = m as u32;
        let dd = d as u32;
        let cmd = format!(":SC {:02}/{:02}/{:02}#", mm, dd, yy);
        mount_log(&format!("[LX200] Sending: {}", cmd));
        let resp = self.command_fixed(&cmd, 1);
        mount_log(&format!("[LX200] :SC response byte: {:?}", resp));
        if matches!(resp.as_deref(), Ok("0")) {
            // Standard format failed — try without space (some firmwares)
            std::thread::sleep(Duration::from_millis(200));
            self.transport.clear_buffers()?;
            let cmd = format!(":SC{:02}/{:02}/{:02}#", mm, dd, yy);
            mount_log(&format!("[LX200] Retrying without space: {}", cmd));
            let resp = self.command_fixed(&cmd, 1);
            mount_log(&format!("[LX200] :SC retry response: {:?}", resp));
        }
        // Drain trailing "Updating Planetary Data#...#"
        std::thread::sleep(Duration::from_millis(500));
        self.transport.clear_buffers()?;

        // Read back all settings to verify
        mount_log("[LX200] === Verifying settings ===");
        if let Ok(v) = self.command(":GG#") { mount_log(&format!("[LX200] Read back UTC off  :GG# = {:?}", v)); }
        if let Ok(v) = self.command(":Gt#") { mount_log(&format!("[LX200] Read back Site lat :Gt# = {:?}", v)); }
        if let Ok(v) = self.command(":Gg#") { mount_log(&format!("[LX200] Read back Site lon :Gg# = {:?}", v)); }
        if let Ok(v) = self.command(":GL#") { mount_log(&format!("[LX200] Read back Local tm :GL# = {:?}", v)); }
        if let Ok(v) = self.command(":GC#") { mount_log(&format!("[LX200] Read back Date     :GC# = {:?}", v)); }

        mount_log("[LX200] sync_datetime complete");
        Ok(())
    }

    /// Park (go home). AM5 INDI driver uses :hC# (go to home position).
    pub fn park(&mut self) -> Result<(), MountError> {
        self.command_blind(":hC#")
    }

    /// Unpark — enable tracking which takes the AM5 out of home/park state.
    pub fn unpark(&mut self) -> Result<(), MountError> {
        self.set_tracking(true)
    }

    pub fn abort(&mut self) -> Result<(), MountError> {
        self.command_blind(":Q#")
    }
}

impl super::MountBackendTrait for Lx200Client {
    fn get_status(&mut self) -> Result<MountStatus, MountError> {
        Lx200Client::get_status(self)
    }

    fn slew_ra_degrees(&mut self, degrees: f64) -> Result<(), MountError> {
        Lx200Client::slew_ra_degrees(self, degrees)
    }

    fn set_tracking(&mut self, enabled: bool) -> Result<(), MountError> {
        Lx200Client::set_tracking(self, enabled)
    }

    fn abort(&mut self) -> Result<(), MountError> {
        Lx200Client::abort(self)
    }

    fn backend_name(&self) -> &str {
        "LX200"
    }

    fn goto_radec(&mut self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        Lx200Client::goto_radec(self, ra_hours, dec_deg)
    }

    fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), MountError> {
        Lx200Client::set_tracking_rate(self, rate)
    }

    fn move_axis(&mut self, axis: u8, rate_deg_per_sec: f64) -> Result<(), MountError> {
        Lx200Client::move_axis(self, axis, rate_deg_per_sec)
    }

    fn park(&mut self) -> Result<(), MountError> {
        Lx200Client::park(self)
    }

    fn unpark(&mut self) -> Result<(), MountError> {
        Lx200Client::unpark(self)
    }

    fn sync_position(&mut self, ra_hours: f64, dec_deg: f64) -> Result<(), MountError> {
        Lx200Client::sync_position(self, ra_hours, dec_deg)
    }

    fn sync_datetime(&mut self, observer_lat_deg: f64, observer_lon_deg: f64, utc_offset_hours: f64) -> Result<(), MountError> {
        Lx200Client::sync_datetime(self, observer_lat_deg, observer_lon_deg, utc_offset_hours)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_ra() {
        assert!((Lx200Client::parse_ra("12:30:00").unwrap() - 12.5).abs() < 0.001);
        assert!((Lx200Client::parse_ra("00:00:00").unwrap()).abs() < 0.001);
        assert!((Lx200Client::parse_ra("23:59:59").unwrap() - 23.9997).abs() < 0.001);
    }

    #[test]
    fn test_parse_dec() {
        assert!((Lx200Client::parse_dec("+45*30:00").unwrap() - 45.5).abs() < 0.001);
        assert!((Lx200Client::parse_dec("-12*15:30").unwrap() - (-12.2583)).abs() < 0.001);
    }
}
