use crate::coordinates::*;

/// Errors that can occur during alignment computation.
/// Variants must match the UDL [Error] enum definition exactly.
#[derive(Debug, thiserror::Error)]
pub enum AlignmentError {
    #[error("The three positions are collinear — cannot determine rotation axis")]
    CollinearPoints,
    #[error("Invalid coordinates provided")]
    InvalidCoordinates,
    #[error("Computation failed")]
    ComputationFailed,
}

/// Compute polar alignment error from three plate-solved positions.
///
/// The three positions are captured at different RA rotations of the mount.
/// The center of the circle they trace on the celestial sphere is where
/// the mount's RA axis actually points.
///
/// # Arguments
/// - `pos1`, `pos2`, `pos3`: Plate-solved (RA, Dec) at three RA positions
/// - `observer_lat_deg`: Observer latitude (north positive)
/// - `observer_lon_deg`: Observer longitude (east positive)
/// - `timestamp_jd`: Julian Date of observation
///
/// # Returns
/// `PolarError` with altitude and azimuth corrections in arcminutes.
/// Positive altitude = mount axis too high, lower it.
/// Positive azimuth = mount axis too far east, move west.
pub fn compute_polar_error(
    pos1: CelestialCoord,
    pos2: CelestialCoord,
    pos3: CelestialCoord,
    observer_lat_deg: f64,
    observer_lon_deg: f64,
    timestamp_jd: f64,
) -> Result<PolarError, AlignmentError> {
    // Convert three solved positions to Cartesian unit vectors
    let p1 = celestial_to_cartesian(pos1.ra_deg, pos1.dec_deg);
    let p2 = celestial_to_cartesian(pos2.ra_deg, pos2.dec_deg);
    let p3 = celestial_to_cartesian(pos3.ra_deg, pos3.dec_deg);

    // Two difference vectors in the plane of the three points
    let d1 = [p2[0] - p1[0], p2[1] - p1[1], p2[2] - p1[2]];
    let d2 = [p3[0] - p1[0], p3[1] - p1[1], p3[2] - p1[2]];

    // Cross product gives the normal to the plane = rotation axis
    let axis_raw = cross(d1, d2);
    let axis_len = (axis_raw[0] * axis_raw[0]
        + axis_raw[1] * axis_raw[1]
        + axis_raw[2] * axis_raw[2])
        .sqrt();

    if axis_len < 1e-10 {
        return Err(AlignmentError::CollinearPoints);
    }

    // Normalize. The axis could point toward either pole of the rotation.
    // We choose the one closer to the celestial pole (Dec > 0 for northern,
    // Dec < 0 for southern hemisphere).
    let mut axis = normalize(axis_raw);

    // For northern hemisphere observer, the axis should point toward +Z (Dec > 0)
    // For southern, toward -Z (Dec < 0)
    if (observer_lat_deg >= 0.0 && axis[2] < 0.0)
        || (observer_lat_deg < 0.0 && axis[2] > 0.0)
    {
        axis = [-axis[0], -axis[1], -axis[2]];
    }

    // Convert mount axis to RA/Dec
    let mount_axis = cartesian_to_celestial(axis);

    // Convert mount axis to Alt/Az
    let mount_altaz = celestial_to_altaz(mount_axis, observer_lat_deg, observer_lon_deg, timestamp_jd);

    // True celestial pole in Alt/Az:
    //   Northern hemisphere: Alt = latitude, Az = 0° (due north)
    //   Southern hemisphere: Alt = |latitude|, Az = 180° (due south)
    let (pole_alt, pole_az) = if observer_lat_deg >= 0.0 {
        (observer_lat_deg, 0.0)
    } else {
        (-observer_lat_deg, 180.0)
    };

    // Compute corrections needed
    let alt_error = (mount_altaz.alt_deg - pole_alt) * 60.0; // arcminutes

    // Azimuth error needs to account for the cosine projection at the altitude
    let mut az_diff = mount_altaz.az_deg - pole_az;
    // Normalize to [-180, 180]
    if az_diff > 180.0 {
        az_diff -= 360.0;
    }
    if az_diff < -180.0 {
        az_diff += 360.0;
    }
    let az_error = az_diff * 60.0 * mount_altaz.alt_deg.to_radians().cos();

    let total = (alt_error * alt_error + az_error * az_error).sqrt();

    Ok(PolarError {
        alt_error_arcmin: alt_error,
        az_error_arcmin: az_error,
        total_error_arcmin: total,
        mount_axis,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time_utils::julian_date;

    #[test]
    fn test_perfect_alignment() {
        // Simulate a perfectly aligned mount at latitude 60° N.
        // When we rotate in RA, the three positions should trace a circle
        // centered exactly on the north celestial pole (Dec=90).
        //
        // Camera pointing at Dec=80, rotating in RA by 30° each time.
        let dec = 80.0_f64;
        let pos1 = CelestialCoord { ra_deg: 0.0, dec_deg: dec };
        let pos2 = CelestialCoord { ra_deg: 30.0, dec_deg: dec };
        let pos3 = CelestialCoord { ra_deg: 60.0, dec_deg: dec };

        let jd = julian_date(2026, 3, 10, 22, 0, 0.0);
        let result = compute_polar_error(pos1, pos2, pos3, 60.17, 24.94, jd).unwrap();

        assert!(
            result.total_error_arcmin < 1.0,
            "Perfect alignment should have near-zero error, got {:.2}'",
            result.total_error_arcmin
        );
    }

    #[test]
    fn test_deliberate_altitude_offset() {
        // Mount axis pointing 1° above the pole.
        // At latitude 60°, pole is at Alt=60°. If mount axis is at Alt=61°,
        // that's Dec=91° which is invalid. Instead, simulate the offset by
        // rotating around an axis at Dec=89° (1° off from pole).
        //
        // Three points on a circle centered at Dec=89° (RA=0°):
        // Using the small-circle formula: at angular distance 10° from center,
        // the declinations change as we rotate in RA around the offset axis.
        let center_dec = 89.0; // 1 degree off
        let angular_radius = 10.0_f64.to_radians();
        let center = celestial_to_cartesian(0.0, center_dec);

        // Generate 3 points on the small circle at 0°, 120°, 240°
        let positions: Vec<CelestialCoord> = [0.0_f64, 120.0, 240.0]
            .iter()
            .map(|angle_deg| {
                let angle = (*angle_deg).to_radians();
                // Rodrigues' rotation: rotate a point at `angular_radius` from center
                // around the center axis
                let perp1 = normalize(cross(center, [0.0, 1.0, 0.0]));
                let perp2 = normalize(cross(center, perp1));
                let point = [
                    center[0] * angular_radius.cos()
                        + perp1[0] * angular_radius.sin() * angle.cos()
                        + perp2[0] * angular_radius.sin() * angle.sin(),
                    center[1] * angular_radius.cos()
                        + perp1[1] * angular_radius.sin() * angle.cos()
                        + perp2[1] * angular_radius.sin() * angle.sin(),
                    center[2] * angular_radius.cos()
                        + perp1[2] * angular_radius.sin() * angle.cos()
                        + perp2[2] * angular_radius.sin() * angle.sin(),
                ];
                cartesian_to_celestial(normalize(point))
            })
            .collect();

        let jd = julian_date(2026, 3, 10, 22, 0, 0.0);
        let result = compute_polar_error(
            positions[0], positions[1], positions[2],
            60.17, 24.94, jd,
        )
        .unwrap();

        // The total error should be approximately 60 arcminutes (1 degree)
        assert!(
            (result.total_error_arcmin - 60.0).abs() < 10.0,
            "Expected ~60' total error for 1° offset, got {:.1}'",
            result.total_error_arcmin
        );
    }

    #[test]
    fn test_identical_points_error() {
        // Three identical points — can't define a circle
        let pos = CelestialCoord { ra_deg: 100.0, dec_deg: 45.0 };
        let jd = julian_date(2026, 3, 10, 22, 0, 0.0);
        let result = compute_polar_error(pos, pos, pos, 60.17, 24.94, jd);
        assert!(result.is_err(), "Identical points should produce CollinearPoints error");
    }

    #[test]
    fn test_nearly_collinear_points_error() {
        // Three points nearly on the same great circle arc (tiny angular separation)
        let pos1 = CelestialCoord { ra_deg: 100.0, dec_deg: 45.0 };
        let pos2 = CelestialCoord { ra_deg: 100.0, dec_deg: 45.0000001 };
        let pos3 = CelestialCoord { ra_deg: 100.0, dec_deg: 45.0000002 };

        let jd = julian_date(2026, 3, 10, 22, 0, 0.0);
        let result = compute_polar_error(pos1, pos2, pos3, 60.17, 24.94, jd);
        assert!(result.is_err(), "Nearly collinear points should fail");
    }
}
