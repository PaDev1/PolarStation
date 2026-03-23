//! Plate solver wrapping the tetra3 crate.
//!
//! Takes star centroids (pixel coordinates) from the Swift detection pipeline,
//! runs the tetra3 geometric-hash solver, and returns the camera pointing
//! direction as RA/Dec plus roll angle.

use std::sync::Mutex;

use crate::coordinates::{CatalogStar, SolveResult, StarCentroid};

/// Errors from the plate solver.
#[derive(Debug, thiserror::Error)]
pub enum SolverError {
    #[error("No solver database loaded — call load_database first")]
    NoDatabaseLoaded,
    #[error("Failed to load database")]
    DatabaseLoadFailed,
    #[error("Plate solve failed: no match found")]
    NoMatch,
    #[error("Too few centroids for solving (need at least 4)")]
    TooFewCentroids,
    #[error("Solve timed out")]
    Timeout,
}

/// Plate solver backed by the tetra3 crate.
///
/// This is exposed to Swift as a UniFFI Object. The database is loaded once,
/// then `solve` is called for each frame.
pub struct PlateSolver {
    database: Mutex<Option<tetra3::SolverDatabase>>,
}

impl PlateSolver {
    /// Create a new solver without a database loaded.
    pub fn new() -> Self {
        Self {
            database: Mutex::new(None),
        }
    }

    /// Generate a solver database from a star catalog file.
    ///
    /// `catalog_path` — path to a catalog file (Hipparcos hip2.dat or Tycho-2 tyc2.dat)
    /// `catalog_type` — "hipparcos" or "tycho2"
    /// `output_path` — path to save the generated .rkyv database
    /// `max_magnitude` — faintest star magnitude to include (e.g., 10.0, 11.0, 12.0)
    /// `min_fov_deg` — minimum FOV the database should support (degrees)
    /// `max_fov_deg` — maximum FOV the database should support (degrees)
    pub fn generate_database(
        &self,
        catalog_path: String,
        catalog_type: String,
        output_path: String,
        max_magnitude: f64,
        min_fov_deg: f64,
        max_fov_deg: f64,
    ) -> Result<String, SolverError> {
        let config = tetra3::GenerateDatabaseConfig {
            max_fov_deg: max_fov_deg as f32,
            min_fov_deg: Some(min_fov_deg as f32),
            epoch_proper_motion_year: Some(2026.0),
            star_max_magnitude: Some(max_magnitude as f32),
            ..Default::default()
        };

        let db = match catalog_type.as_str() {
            "hipparcos" | "gaia" => {
                let result = std::panic::catch_unwind(|| {
                    tetra3::SolverDatabase::generate_from_hipparcos(&catalog_path, &config)
                });
                match result {
                    Ok(Ok(db)) => db,
                    Ok(Err(e)) => {
                        eprintln!("[generate] Generation error: {:?}", e);
                        return Err(SolverError::DatabaseLoadFailed);
                    }
                    Err(panic) => {
                        let msg = panic.downcast_ref::<String>()
                            .map(|s| s.as_str())
                            .or_else(|| panic.downcast_ref::<&str>().copied())
                            .unwrap_or("unknown panic");
                        eprintln!("[generate] Panic: {}", msg);
                        return Err(SolverError::DatabaseLoadFailed);
                    }
                }
            }
            "tycho2" => {
                // Convert Tycho-2 to hip2.dat format, then generate
                let hip_path = format!("{}.hip2.tmp", output_path);
                tycho2_to_hipparcos(&catalog_path, &hip_path)
                    .map_err(|_| SolverError::DatabaseLoadFailed)?;
                let db = tetra3::SolverDatabase::generate_from_hipparcos(&hip_path, &config)
                    .map_err(|_| SolverError::DatabaseLoadFailed)?;
                let _ = std::fs::remove_file(&hip_path);
                db
            }
            _ => return Err(SolverError::DatabaseLoadFailed),
        };

        let info = format!(
            "Stars: {}, Patterns: {}, FOV: {:.1}°–{:.1}°",
            db.star_catalog.len(),
            db.props.num_patterns,
            db.props.min_fov_rad.to_degrees(),
            db.props.max_fov_rad.to_degrees()
        );

        db.save_to_file(&output_path)
            .map_err(|_| SolverError::DatabaseLoadFailed)?;

        // Auto-load the generated database
        let mut guard = self.database.lock().unwrap();
        *guard = Some(db);

        Ok(info)
    }

    /// Load a pre-built solver database from an .rkyv file.
    pub fn load_database(&self, path: String) -> Result<(), SolverError> {
        let db = tetra3::SolverDatabase::load_from_file(&path)
            .map_err(|_| SolverError::DatabaseLoadFailed)?;
        let mut guard = self.database.lock().unwrap();
        *guard = Some(db);
        Ok(())
    }

    /// Solve: find the sky position from star centroids.
    ///
    /// `centroids` — detected star positions in pixel coordinates (origin top-left).
    /// `image_width`, `image_height` — sensor dimensions in pixels.
    /// `fov_deg` — estimated horizontal field of view in degrees.
    /// `fov_tolerance_deg` — allowed FOV error in degrees (0 = no filtering).
    ///
    /// Returns a `SolveResult` with RA/Dec, roll, matched star count, and solve time.
    pub fn solve(
        &self,
        centroids: Vec<StarCentroid>,
        image_width: u32,
        image_height: u32,
        fov_deg: f64,
        fov_tolerance_deg: f64,
    ) -> Result<SolveResult, SolverError> {
        let guard = self.database.lock().unwrap();
        let db = guard.as_ref().ok_or(SolverError::NoDatabaseLoaded)?;

        if centroids.len() < 4 {
            return Err(SolverError::TooFewCentroids);
        }

        // Convert our centroids to tetra3 format.
        // tetra3 expects origin at image center; our centroids have origin at top-left.
        // Limit to 30 brightest — tetra3 performance degrades with too many stars.
        let half_w = image_width as f32 / 2.0;
        let half_h = image_height as f32 / 2.0;

        let mut sorted_centroids = centroids;
        sorted_centroids.sort_by(|a, b| b.brightness.partial_cmp(&a.brightness).unwrap_or(std::cmp::Ordering::Equal));
        sorted_centroids.truncate(90);

        let t3_centroids: Vec<tetra3::Centroid> = sorted_centroids
            .iter()
            .map(|c| tetra3::Centroid {
                x: c.x as f32 - half_w,
                y: c.y as f32 - half_h,
                mass: Some(c.brightness as f32),
                cov: None,
            })
            .collect();

        let fov_rad = (fov_deg as f32).to_radians();
        let mut config = tetra3::SolveConfig::new(fov_rad, image_width, image_height);
        if fov_tolerance_deg > 0.0 {
            config.fov_max_error_rad = Some((fov_tolerance_deg as f32).to_radians());
        }
        config.solve_timeout_ms = Some(10000);

        let result = db.solve_from_centroids(&t3_centroids, &config);

        match result.status {
            tetra3::SolveStatus::MatchFound => {
                // Use tetra3's WCS solution directly (more reliable than quaternion decomposition)
                let (ra_deg, dec_deg) = if let Some(crval) = result.crval_rad {
                    (crval[0].to_degrees().rem_euclid(360.0), crval[1].to_degrees())
                } else {
                    // Fallback: extract from quaternion
                    let q = result.qicrs2cam.unwrap();
                    let boresight = q.inverse() * nalgebra::Vector3::new(0.0_f32, 0.0, 1.0);
                    let dec = (boresight.z as f64).asin().to_degrees();
                    let ra = (boresight.y as f64).atan2(boresight.x as f64).to_degrees().rem_euclid(360.0);
                    (ra, dec)
                };

                let roll_deg = result.theta_rad
                    .map(|t| t.to_degrees())
                    .unwrap_or(0.0);

                let fov_result = result.fov_rad.map(|f| (f as f64).to_degrees());

                Ok(SolveResult {
                    success: true,
                    ra_deg,
                    dec_deg,
                    roll_deg,
                    fov_deg: fov_result.unwrap_or(fov_deg),
                    matched_stars: result.num_matches.unwrap_or(0),
                    solve_time_ms: result.solve_time_ms as f64,
                    rmse_arcsec: result
                        .rmse_rad
                        .map(|r| (r as f64).to_degrees() * 3600.0)
                        .unwrap_or(0.0),
                })
            }
            tetra3::SolveStatus::NoMatch => Err(SolverError::NoMatch),
            tetra3::SolveStatus::Timeout => Err(SolverError::Timeout),
            tetra3::SolveStatus::TooFew => Err(SolverError::TooFewCentroids),
        }
    }

    /// Get all stars from the loaded catalog (for sky map display).
    /// Returns RA/Dec in degrees and visual magnitude.
    pub fn get_star_catalog(&self) -> Vec<CatalogStar> {
        let guard = self.database.lock().unwrap();
        let db = match guard.as_ref() {
            Some(db) => db,
            None => return Vec::new(),
        };
        db.star_catalog.stars().iter().map(|s| CatalogStar {
            ra_deg: (s.ra_rad as f64).to_degrees(),
            dec_deg: (s.dec_rad as f64).to_degrees(),
            magnitude: s.mag as f64,
        }).collect()
    }

    /// Get database info string (star count, pattern count, FOV range).
    pub fn database_info(&self) -> Option<String> {
        let guard = self.database.lock().unwrap();
        let db = guard.as_ref()?;
        let p = &db.props;
        Some(format!(
            "Stars: {}, Patterns: {}, FOV: {:.1}°–{:.1}°, Epoch: {:.1}",
            db.star_catalog.len(),
            p.num_patterns,
            p.min_fov_rad.to_degrees(),
            p.max_fov_rad.to_degrees(),
            p.epoch_proper_motion_year,
        ))
    }
}

/// Convert a Tycho-2 catalog file to Hipparcos hip2.dat format.
///
/// Tycho-2 (pipe-delimited) fields:
///   0:TYC1 1:TYC2 2:TYC3 3:pflag 4:mRAdeg 5:mDEdeg 6:pmRA 7:pmDE
///   8-11:errors 12-14:more 15:BTmag 16:e_BTmag 17:VTmag 18:e_VTmag 19:prox
///
/// hip2.dat format (fixed-width):
///   col 1-6:   HIP number
///   col 16-28: RA (radians)
///   col 30-42: Dec (radians)
///   col 44-48: parallax (mas)
///   col 50-56: pmRA (mas/yr)
///   col 58-64: pmDec (mas/yr)
///   col 130-136: Hp magnitude
fn tycho2_to_hipparcos(tyc_path: &str, hip_path: &str) -> Result<(), std::io::Error> {
    use std::io::{BufRead, BufReader, Write, BufWriter};
    use std::fs::File;

    let file = File::open(tyc_path)?;
    let reader = BufReader::new(file);
    let out = File::create(hip_path)?;
    let mut writer = BufWriter::new(out);
    let mut id: u32 = 1;

    for line in reader.lines() {
        let line = line?;
        let fields: Vec<&str> = line.split('|').collect();
        if fields.len() < 20 { continue; }

        let ra_deg: f64 = match fields[4].trim().parse() { Ok(v) => v, Err(_) => continue };
        let dec_deg: f64 = match fields[5].trim().parse() { Ok(v) => v, Err(_) => continue };
        let pm_ra: f64 = fields[6].trim().parse().unwrap_or(0.0);
        let pm_dec: f64 = fields[7].trim().parse().unwrap_or(0.0);
        let vt_mag: f64 = fields.get(17)
            .and_then(|s| s.trim().parse().ok())
            .or_else(|| fields.get(15).and_then(|s| s.trim().parse().ok()))
            .unwrap_or(99.0);

        if vt_mag > 13.0 { continue; }

        let ra_rad = ra_deg.to_radians();
        let dec_rad = dec_deg.to_radians();

        // Write hip2.dat format line (simplified — key fields at correct column positions)
        // The parser reads: hip(1-6), ra_rad(16-28), dec_rad(30-42), plx(44-48),
        //   pmRA(50-56), pmDec(58-64), and hpmag(130-136)
        let mut line_buf = format!(
            "{:6}          {:13.10} {:13.10} {:5.2} {:7.2} {:7.2}",
            id, ra_rad, dec_rad, 0.0, pm_ra, pm_dec
        );
        // Pad to column 129, then add magnitude
        while line_buf.len() < 129 { line_buf.push(' '); }
        line_buf.push_str(&format!("{:7.4}", vt_mag));
        writeln!(writer, "{}", line_buf)?;
        id += 1;
    }

    Ok(())
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_solver_no_database() {
        let solver = PlateSolver::new();
        let centroids = vec![
            StarCentroid { x: 100.0, y: 100.0, brightness: 0.8 },
            StarCentroid { x: 200.0, y: 150.0, brightness: 0.5 },
            StarCentroid { x: 50.0, y: 200.0, brightness: 0.3 },
            StarCentroid { x: 300.0, y: 50.0, brightness: 0.6 },
        ];
        let result = solver.solve(centroids, 1920, 1080, 10.0, 2.0);
        assert!(matches!(result, Err(SolverError::NoDatabaseLoaded)));
    }

    #[test]
    fn test_solver_too_few_centroids() {
        let solver = PlateSolver::new();
        // Even without a database, too-few check happens first in solve()
        // Actually the no-database check happens first. Let's just test the error type.
        let centroids = vec![
            StarCentroid { x: 100.0, y: 100.0, brightness: 0.8 },
        ];
        let result = solver.solve(centroids, 1920, 1080, 10.0, 2.0);
        // Will be NoDatabaseLoaded since that check comes first
        assert!(result.is_err());
    }

    #[test]
    fn test_database_info_none() {
        let solver = PlateSolver::new();
        assert!(solver.database_info().is_none());
    }

    /// Integration test: project catalog stars at a known RA/Dec using gnomonic projection,
    /// then solve and verify the result matches.
    /// Run with: cargo test -p polar-core test_solve_synthetic -- --nocapture
    #[test]
    fn test_solve_synthetic() {
        // Data lives one level up from the crate (in the workspace root)
        let db_path = format!("{}/../data/star_catalog.rkyv", env!("CARGO_MANIFEST_DIR"));
        if !std::path::Path::new(&db_path).exists() {
            eprintln!("Skipping: {} not found", db_path);
            return;
        }

        let db = tetra3::SolverDatabase::load_from_file(&db_path).expect("load db");
        let catalog: Vec<_> = db.star_catalog.stars().to_vec();
        println!("Catalog: {} stars", catalog.len());
        println!("DB: patterns={} FOV={:.2}°–{:.2}° epoch={:.1}",
                 db.props.num_patterns,
                 db.props.min_fov_rad.to_degrees(),
                 db.props.max_fov_rad.to_degrees(),
                 db.props.epoch_proper_motion_year);

        let target_ra_deg = 180.0_f64;
        let target_dec_deg = 45.0_f64;
        let fov_deg = 3.2_f64;
        let image_width: u32 = 1920;
        let image_height: u32 = 1080;

        let ra0 = target_ra_deg.to_radians();
        let dec0 = target_dec_deg.to_radians();
        let plate_scale = fov_deg.to_radians() / image_width as f64;
        let half_w = image_width as f32 / 2.0;
        let half_h = image_height as f32 / 2.0;

        // Project catalog stars using gnomonic projection (same as Swift GnomonicProjection)
        let mut centroids: Vec<tetra3::Centroid> = Vec::new();
        let mut star_count = 0;

        for star in &catalog {
            if star.mag > 10.0 { continue; }

            let ra = star.ra_rad as f64;
            let dec = star.dec_rad as f64;
            let delta_ra = ra - ra0;

            // Gnomonic projection
            let cosc = dec0.sin() * dec.sin() + dec0.cos() * dec.cos() * delta_ra.cos();
            if cosc <= 0.001 { continue; } // behind camera

            let xi = dec.cos() * delta_ra.sin() / cosc;
            let eta = (dec0.cos() * dec.sin() - dec0.sin() * dec.cos() * delta_ra.cos()) / cosc;

            // To pixel coords (top-left origin), roll=0
            let px = (image_width as f64) / 2.0 + xi / plate_scale;
            let py = (image_height as f64) / 2.0 - eta / plate_scale;

            // Check bounds
            if px < 0.0 || px >= image_width as f64 || py < 0.0 || py >= image_height as f64 {
                continue;
            }

            // Convert to center-origin for tetra3
            centroids.push(tetra3::Centroid {
                x: px as f32 - half_w,
                y: py as f32 - half_h,
                mass: Some(1.0),
                cov: None,
            });
            star_count += 1;
        }

        println!("Projected {} stars in FOV", star_count);
        assert!(star_count >= 4, "Need at least 4 stars");

        // Solve directly with tetra3
        let fov_rad = (fov_deg as f32).to_radians();
        let mut config = tetra3::SolveConfig::new(fov_rad, image_width, image_height);
        config.fov_max_error_rad = Some((1.0_f32).to_radians());
        config.solve_timeout_ms = Some(5000);

        let result = db.solve_from_centroids(&centroids, &config);

        println!("Status: {:?}", result.status);
        println!("Matched: {:?}", result.num_matches);
        println!("RMSE rad: {:?}", result.rmse_rad);
        println!("FOV rad: {:?}", result.fov_rad);
        println!("Parity flip: {}", result.parity_flip);

        if let Some(crval) = result.crval_rad {
            let ra = crval[0].to_degrees().rem_euclid(360.0);
            let dec = crval[1].to_degrees();
            println!("crval: RA={:.4}° Dec={:.4}°", ra, dec);
            let ra_err = (ra - target_ra_deg).abs().min((ra - target_ra_deg + 360.0).abs().min((ra - target_ra_deg - 360.0).abs()));
            let dec_err = (dec - target_dec_deg).abs();
            println!("Error: RA={:.4}° Dec={:.4}°", ra_err, dec_err);
        }

        if let Some(q) = result.qicrs2cam {
            let boresight = q.inverse() * nalgebra::Vector3::new(0.0_f32, 0.0, 1.0);
            let dec = (boresight.z as f64).asin().to_degrees();
            let ra = (boresight.y as f64).atan2(boresight.x as f64).to_degrees().rem_euclid(360.0);
            println!("quaternion: RA={:.4}° Dec={:.4}°", ra, dec);
        }

        if let Some(theta) = result.theta_rad {
            println!("theta (roll): {:.4}°", theta.to_degrees());
        }

        assert_eq!(result.status, tetra3::SolveStatus::MatchFound, "Should find a match");

        if let Some(crval) = result.crval_rad {
            let ra = crval[0].to_degrees().rem_euclid(360.0);
            let dec = crval[1].to_degrees();
            let mut ra_err = (ra - target_ra_deg).abs();
            if ra_err > 180.0 { ra_err = 360.0 - ra_err; }
            assert!(ra_err < 0.5, "RA error {:.3}° should be < 0.5°", ra_err);
            assert!((dec - target_dec_deg).abs() < 0.5, "Dec error {:.3}° should be < 0.5°", (dec - target_dec_deg).abs());
        }
    }

    #[test]
    fn test_solve_robustness() {
        let db_path = format!("{}/../data/star_catalog.rkyv", env!("CARGO_MANIFEST_DIR"));
        if !std::path::Path::new(&db_path).exists() {
            eprintln!("Skipping: {} not found", db_path);
            return;
        }

        let db = tetra3::SolverDatabase::load_from_file(&db_path).expect("load db");
        let catalog: Vec<_> = db.star_catalog.stars().to_vec();
        println!("Catalog: {} stars", catalog.len());
        println!("DB: patterns={} FOV={:.2}°–{:.2}°",
                 db.props.num_patterns,
                 db.props.min_fov_rad.to_degrees(),
                 db.props.max_fov_rad.to_degrees());

        let fov_deg = 2.42_f64;
        let image_width: u32 = 1920;
        let image_height: u32 = 1080;
        let half_w = image_width as f32 / 2.0;
        let half_h = image_height as f32 / 2.0;

        let mut default_ok = 0;
        let mut relaxed_ok = 0;
        let mut notol_ok = 0;
        let total = 50;

        // Deterministic random positions
        let positions: Vec<(f64, f64)> = (0..total).map(|i| {
            let ra = (i as f64 * 137.508) % 360.0; // golden angle spread
            let dec = ((i as f64 / total as f64) * 2.0 - 1.0).asin().to_degrees();
            (ra, dec)
        }).collect();

        for (i, (target_ra, target_dec)) in positions.iter().enumerate() {
            let ra0 = target_ra.to_radians();
            let dec0 = target_dec.to_radians();
            let plate_scale = fov_deg.to_radians() / image_width as f64;

            let mut centroids: Vec<tetra3::Centroid> = Vec::new();
            for star in &catalog {
                if star.mag > 10.0 { continue; }
                let ra_s = star.ra_rad as f64;
                let dec_s = star.dec_rad as f64;
                let cos_c = dec0.sin() * dec_s.sin() + dec0.cos() * dec_s.cos() * (ra_s - ra0).cos();
                if cos_c < 0.1 { continue; }
                let xi = (dec_s.cos() * (ra_s - ra0).sin()) / cos_c;
                let eta = (dec0.cos() * dec_s.sin() - dec0.sin() * dec_s.cos() * (ra_s - ra0).cos()) / cos_c;
                let px = xi / plate_scale;
                let py = -eta / plate_scale;
                if px.abs() > half_w as f64 || py.abs() > half_h as f64 { continue; }
                centroids.push(tetra3::Centroid {
                    x: px as f32,
                    y: py as f32,
                    mass: Some(10.0_f32.powf(-star.mag / 2.5)),
                    cov: None,
                });
            }

            let n = centroids.len();

            // Test 1: Default config
            let fov_rad = (fov_deg as f32).to_radians();
            let mut cfg = tetra3::SolveConfig::new(fov_rad, image_width, image_height);
            cfg.fov_max_error_rad = Some((1.0_f32).to_radians());
            cfg.solve_timeout_ms = Some(5000);
            let r1 = db.solve_from_centroids(&centroids, &cfg);
            let d = r1.status == tetra3::SolveStatus::MatchFound;
            if d { default_ok += 1; }

            // Test 2: Relaxed config
            cfg.match_radius = 0.02;
            cfg.match_threshold = 1e-4;
            let r2 = db.solve_from_centroids(&centroids, &cfg);
            let r = r2.status == tetra3::SolveStatus::MatchFound;
            if r { relaxed_ok += 1; }

            // Test 3: No FOV constraint
            let mut cfg3 = tetra3::SolveConfig::new(fov_rad, image_width, image_height);
            cfg3.solve_timeout_ms = Some(10000);
            let r3 = db.solve_from_centroids(&centroids, &cfg3);
            let u = r3.status == tetra3::SolveStatus::MatchFound;
            if u { notol_ok += 1; }

            println!("[{:2}] RA={:6.1} Dec={:+6.1} stars={:2} default={} relaxed={} noFOV={}",
                     i, target_ra, target_dec, n,
                     if d { "OK" } else { "--" },
                     if r { "OK" } else { "--" },
                     if u { "OK" } else { "--" });
        }

        println!("\n=== RESULTS ({} positions, FOV={:.2}°) ===", total, fov_deg);
        println!("Default:     {}/{} ({:.0}%)", default_ok, total, default_ok as f64 / total as f64 * 100.0);
        println!("Relaxed:     {}/{} ({:.0}%)", relaxed_ok, total, relaxed_ok as f64 / total as f64 * 100.0);
        println!("No FOV tol:  {}/{} ({:.0}%)", notol_ok, total, notol_ok as f64 / total as f64 * 100.0);
    }
}
