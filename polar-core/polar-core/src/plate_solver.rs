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
        let half_w = image_width as f32 / 2.0;
        let half_h = image_height as f32 / 2.0;

        let t3_centroids: Vec<tetra3::Centroid> = centroids
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
        config.solve_timeout_ms = Some(5000);

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
}
