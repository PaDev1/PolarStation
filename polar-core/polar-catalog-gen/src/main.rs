//! Generate the tetra3 solver database from the Hipparcos catalog.
//!
//! Usage:
//!   cargo run -p polar-catalog-gen -- --catalog data/hip2.dat --output star_catalog.rkyv
//!
//! The hip2.dat file can be downloaded from:
//!   http://cdsarc.u-strasbg.fr/ftp/I/311/hip2.dat.gz

use anyhow::Result;
use tetra3::{GenerateDatabaseConfig, SolverDatabase};

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();

    let catalog_path = args
        .iter()
        .position(|a| a == "--catalog")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str())
        .unwrap_or("data/hip2.dat");

    let output_path = args
        .iter()
        .position(|a| a == "--output")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str())
        .unwrap_or("star_catalog.rkyv");

    let max_fov: f32 = args.iter().position(|a| a == "--max-fov")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(5.0);

    let min_fov: f32 = args.iter().position(|a| a == "--min-fov")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.5);

    let max_mag: f32 = args.iter().position(|a| a == "--max-mag")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(10.0);

    let config = GenerateDatabaseConfig {
        max_fov_deg: max_fov,
        min_fov_deg: Some(min_fov),
        epoch_proper_motion_year: Some(2026.0),
        star_max_magnitude: Some(max_mag),
        ..Default::default()
    };

    println!("Generating solver database...");
    println!("  Catalog: {}", catalog_path);
    println!("  FOV range: {:.1}°–{:.1}°",
        config.min_fov_deg.unwrap_or(config.max_fov_deg), config.max_fov_deg);
    println!("  Epoch: {:.1}", config.epoch_proper_motion_year.unwrap_or(2000.0));
    println!("  Max magnitude: {:.1}", config.star_max_magnitude.unwrap_or(0.0));

    let db = SolverDatabase::generate_from_hipparcos(catalog_path, &config)?;

    println!("\nDatabase stats:");
    println!("  Stars: {}", db.star_catalog.len());
    println!("  Patterns: {}", db.props.num_patterns);
    println!("  FOV: {:.2}°–{:.2}°",
        db.props.min_fov_rad.to_degrees(),
        db.props.max_fov_rad.to_degrees());

    db.save_to_file(output_path)?;
    println!("\nSaved to: {}", output_path);

    // Print file size
    let metadata = std::fs::metadata(output_path)?;
    let size_mb = metadata.len() as f64 / (1024.0 * 1024.0);
    println!("File size: {:.1} MB", size_mb);

    Ok(())
}
