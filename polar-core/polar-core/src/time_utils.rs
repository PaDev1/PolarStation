/// Compute Julian Date from UTC date/time components.
///
/// Valid for dates after 1582-10-15 (Gregorian calendar).
pub fn julian_date(year: i32, month: u32, day: u32, hour: u32, min: u32, sec: f64) -> f64 {
    let y = if month <= 2 { year - 1 } else { year } as f64;
    let m = if month <= 2 { month + 12 } else { month } as f64;
    let d = day as f64;
    let ut = hour as f64 + min as f64 / 60.0 + sec / 3600.0;

    let a = (y / 100.0).floor();
    let b = 2.0 - a + (a / 4.0).floor();

    (365.25 * (y + 4716.0)).floor() + (30.6001 * (m + 1.0)).floor() + d + ut / 24.0 + b - 1524.5
}

/// Greenwich Mean Sidereal Time in degrees for a given Julian Date.
pub fn gmst_deg(jd: f64) -> f64 {
    // Julian centuries since J2000.0
    let t = (jd - 2451545.0) / 36525.0;

    // GMST at 0h UT in degrees (IAU 1982 model)
    let gmst = 280.46061837
        + 360.98564736629 * (jd - 2451545.0)
        + 0.000387933 * t * t
        - t * t * t / 38710000.0;

    gmst.rem_euclid(360.0)
}

/// Local Sidereal Time in degrees for a given JD and east longitude (degrees).
pub fn local_sidereal_time(jd: f64, longitude_deg: f64) -> f64 {
    (gmst_deg(jd) + longitude_deg).rem_euclid(360.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_julian_date_j2000() {
        // J2000.0 epoch: 2000-01-01 12:00:00 TT = JD 2451545.0
        let jd = julian_date(2000, 1, 1, 12, 0, 0.0);
        assert!((jd - 2451545.0).abs() < 0.0001, "J2000 epoch: got {jd}");
    }

    #[test]
    fn test_julian_date_known() {
        // 2024-03-20 00:00:00 UT = JD 2460389.5
        let jd = julian_date(2024, 3, 20, 0, 0, 0.0);
        assert!((jd - 2460389.5).abs() < 0.001, "2024-03-20: got {jd}");
    }

    #[test]
    fn test_gmst_j2000() {
        // At J2000.0 epoch, GMST ≈ 280.46°
        let gmst = gmst_deg(2451545.0);
        assert!((gmst - 280.46).abs() < 0.1, "GMST at J2000: got {gmst}");
    }

    #[test]
    fn test_lst_greenwich() {
        // LST at Greenwich (lon=0) should equal GMST
        let jd = 2451545.0;
        let lst = local_sidereal_time(jd, 0.0);
        let gmst = gmst_deg(jd);
        assert!((lst - gmst).abs() < 0.001);
    }

    #[test]
    fn test_lst_offset() {
        let jd = 2451545.0;
        let lst_east = local_sidereal_time(jd, 90.0);
        let lst_greenwich = local_sidereal_time(jd, 0.0);
        let diff = (lst_east - lst_greenwich).rem_euclid(360.0);
        assert!((diff - 90.0).abs() < 0.001);
    }
}
