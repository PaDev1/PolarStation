/// Equatorial coordinates (RA/Dec) in degrees.
#[derive(Debug, Clone, Copy)]
pub struct CelestialCoord {
    pub ra_deg: f64,
    pub dec_deg: f64,
}

/// Horizontal coordinates (Alt/Az) in degrees.
#[derive(Debug, Clone, Copy)]
pub struct AltAzCoord {
    pub alt_deg: f64,
    pub az_deg: f64,
}

/// A detected star's position and brightness.
#[derive(Debug, Clone, Copy)]
pub struct StarCentroid {
    pub x: f64,
    pub y: f64,
    pub brightness: f64,
}

/// Result from plate solving.
#[derive(Debug, Clone)]
pub struct SolveResult {
    pub success: bool,
    pub ra_deg: f64,
    pub dec_deg: f64,
    pub roll_deg: f64,
    pub fov_deg: f64,
    pub matched_stars: u32,
    pub solve_time_ms: f64,
    pub rmse_arcsec: f64,
}

/// Polar alignment error decomposed into altitude and azimuth.
#[derive(Debug, Clone, Copy)]
pub struct PolarError {
    pub alt_error_arcmin: f64,
    pub az_error_arcmin: f64,
    pub total_error_arcmin: f64,
    pub mount_axis: CelestialCoord,
}

/// Mount connection protocol.
pub enum MountProtocol {
    AlpacaHttp { host: String, port: u16 },
    Lx200Serial { device_path: String, baud: u32 },
}

/// Mount status.
#[derive(Debug, Clone)]
pub struct MountStatus {
    pub connected: bool,
    pub ra_hours: f64,
    pub dec_deg: f64,
    pub tracking: bool,
    pub slewing: bool,
    pub tracking_rate: u8, // 0=sidereal, 1=lunar, 2=solar, 3=king
    pub at_park: bool,
}

/// A star from the catalog (for sky map display).
#[derive(Debug, Clone, Copy)]
pub struct CatalogStar {
    pub ra_deg: f64,
    pub dec_deg: f64,
    pub magnitude: f64,
}

/// Convert RA/Dec (degrees) to a unit Cartesian vector on the celestial sphere.
pub fn celestial_to_cartesian(ra_deg: f64, dec_deg: f64) -> [f64; 3] {
    let ra = ra_deg.to_radians();
    let dec = dec_deg.to_radians();
    [dec.cos() * ra.cos(), dec.cos() * ra.sin(), dec.sin()]
}

/// Convert a unit Cartesian vector to RA/Dec (degrees).
pub fn cartesian_to_celestial(v: [f64; 3]) -> CelestialCoord {
    let dec_deg = v[2].asin().to_degrees();
    let ra_deg = v[1].atan2(v[0]).to_degrees().rem_euclid(360.0);
    CelestialCoord { ra_deg, dec_deg }
}

/// Cross product of two 3-vectors.
pub fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

/// Normalize a 3-vector to unit length.
pub fn normalize(v: [f64; 3]) -> [f64; 3] {
    let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    if len < 1e-15 {
        return [0.0, 0.0, 1.0]; // degenerate — return north pole
    }
    [v[0] / len, v[1] / len, v[2] / len]
}

/// Dot product of two 3-vectors.
pub fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// Convert equatorial (RA/Dec) to horizontal (Alt/Az) coordinates.
///
/// - `coord`: RA/Dec in degrees
/// - `observer_lat_deg`: observer latitude (north positive)
/// - `observer_lon_deg`: observer longitude (east positive)
/// - `timestamp_jd`: Julian Date
///
/// Returns Alt/Az where Az is measured from North through East.
pub fn celestial_to_altaz(
    coord: CelestialCoord,
    observer_lat_deg: f64,
    observer_lon_deg: f64,
    timestamp_jd: f64,
) -> AltAzCoord {
    let lst = crate::time_utils::local_sidereal_time(timestamp_jd, observer_lon_deg);
    let ha = (lst - coord.ra_deg).to_radians();
    let dec = coord.dec_deg.to_radians();
    let lat = observer_lat_deg.to_radians();

    let sin_alt = dec.sin() * lat.sin() + dec.cos() * lat.cos() * ha.cos();
    let alt = sin_alt.asin();

    let cos_alt = alt.cos();
    let az = if cos_alt.abs() < 1e-10 {
        0.0 // zenith — azimuth undefined
    } else {
        let sin_az = -dec.cos() * ha.sin() / cos_alt;
        let cos_az = (dec.sin() - lat.sin() * sin_alt) / (lat.cos() * cos_alt);
        sin_az.atan2(cos_az)
    };

    AltAzCoord {
        alt_deg: alt.to_degrees(),
        az_deg: az.to_degrees().rem_euclid(360.0),
    }
}

/// Convert horizontal (Alt/Az) to equatorial (RA/Dec) coordinates.
pub fn altaz_to_celestial(
    altaz: AltAzCoord,
    observer_lat_deg: f64,
    observer_lon_deg: f64,
    timestamp_jd: f64,
) -> CelestialCoord {
    let alt = altaz.alt_deg.to_radians();
    let az = altaz.az_deg.to_radians();
    let lat = observer_lat_deg.to_radians();

    let sin_dec = alt.sin() * lat.sin() + alt.cos() * lat.cos() * az.cos();
    let dec = sin_dec.asin();

    let cos_dec = dec.cos();
    let ha = if cos_dec.abs() < 1e-10 {
        0.0
    } else {
        let sin_ha = -alt.cos() * az.sin() / cos_dec;
        let cos_ha = (alt.sin() - lat.sin() * sin_dec) / (lat.cos() * cos_dec);
        sin_ha.atan2(cos_ha)
    };

    let lst = crate::time_utils::local_sidereal_time(timestamp_jd, observer_lon_deg);
    let ra_deg = (lst - ha.to_degrees()).rem_euclid(360.0);

    CelestialCoord {
        ra_deg,
        dec_deg: dec.to_degrees(),
    }
}

/// Angular separation between two points on the celestial sphere (degrees).
pub fn angular_separation(a: CelestialCoord, b: CelestialCoord) -> f64 {
    let va = celestial_to_cartesian(a.ra_deg, a.dec_deg);
    let vb = celestial_to_cartesian(b.ra_deg, b.dec_deg);
    dot(va, vb).clamp(-1.0, 1.0).acos().to_degrees()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_celestial_cartesian_roundtrip() {
        let ra = 123.456;
        let dec = -34.567;
        let v = celestial_to_cartesian(ra, dec);
        let result = cartesian_to_celestial(v);
        assert!((result.ra_deg - ra).abs() < 1e-10);
        assert!((result.dec_deg - dec).abs() < 1e-10);
    }

    #[test]
    fn test_north_pole_cartesian() {
        let v = celestial_to_cartesian(0.0, 90.0);
        assert!((v[0]).abs() < 1e-10);
        assert!((v[1]).abs() < 1e-10);
        assert!((v[2] - 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_cross_product() {
        let x = [1.0, 0.0, 0.0];
        let y = [0.0, 1.0, 0.0];
        let z = cross(x, y);
        assert!((z[0]).abs() < 1e-10);
        assert!((z[1]).abs() < 1e-10);
        assert!((z[2] - 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_angular_separation_same_point() {
        let a = CelestialCoord { ra_deg: 100.0, dec_deg: 45.0 };
        let sep = angular_separation(a, a);
        assert!(sep.abs() < 1e-10);
    }

    #[test]
    fn test_angular_separation_90_degrees() {
        let a = CelestialCoord { ra_deg: 0.0, dec_deg: 0.0 };
        let b = CelestialCoord { ra_deg: 0.0, dec_deg: 90.0 };
        let sep = angular_separation(a, b);
        assert!((sep - 90.0).abs() < 1e-10);
    }

    #[test]
    fn test_polaris_altitude_equals_latitude() {
        // At the north celestial pole (RA=0, Dec=90), the altitude
        // should approximately equal the observer's latitude.
        let pole = CelestialCoord { ra_deg: 0.0, dec_deg: 90.0 };
        let lat = 60.17; // Helsinki
        let lon = 24.94;
        // Use a JD where LST doesn't matter for the pole
        let jd = 2460388.5;
        let altaz = celestial_to_altaz(pole, lat, lon, jd);
        assert!(
            (altaz.alt_deg - lat).abs() < 0.1,
            "Pole altitude {} should ≈ latitude {}", altaz.alt_deg, lat
        );
    }
}
