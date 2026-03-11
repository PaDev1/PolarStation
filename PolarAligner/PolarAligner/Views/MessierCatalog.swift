import Foundation

/// A deep-sky object from the Messier catalog.
struct MessierObject: Identifiable {
    let id: String       // e.g. "M1"
    let name: String     // e.g. "Crab Nebula"
    let raDeg: Double    // J2000
    let decDeg: Double   // J2000
    let magnitude: Double
    let type: ObjectType

    var raHours: Double { raDeg / 15.0 }

    enum ObjectType: String {
        case galaxy = "Galaxy"
        case nebula = "Nebula"
        case cluster = "Cluster"
        case planetary = "Planetary"
        case globular = "Globular"
        case other = "Other"
    }
}

/// All 110 Messier objects with J2000 coordinates.
let messierCatalog: [MessierObject] = [
    // Nebulae & Supernova Remnants
    MessierObject(id: "M1",  name: "Crab Nebula",           raDeg: 83.633, decDeg: 22.014, magnitude: 8.4, type: .nebula),
    MessierObject(id: "M8",  name: "Lagoon Nebula",         raDeg: 270.924, decDeg: -24.384, magnitude: 6.0, type: .nebula),
    MessierObject(id: "M16", name: "Eagle Nebula",          raDeg: 274.700, decDeg: -13.807, magnitude: 6.0, type: .nebula),
    MessierObject(id: "M17", name: "Omega Nebula",          raDeg: 275.196, decDeg: -16.171, magnitude: 6.0, type: .nebula),
    MessierObject(id: "M20", name: "Trifid Nebula",         raDeg: 270.620, decDeg: -23.033, magnitude: 6.3, type: .nebula),
    MessierObject(id: "M27", name: "Dumbbell Nebula",       raDeg: 299.902, decDeg: 22.721, magnitude: 7.5, type: .planetary),
    MessierObject(id: "M42", name: "Orion Nebula",          raDeg: 83.822, decDeg: -5.391, magnitude: 4.0, type: .nebula),
    MessierObject(id: "M43", name: "De Mairan's Nebula",    raDeg: 83.890, decDeg: -5.268, magnitude: 9.0, type: .nebula),
    MessierObject(id: "M57", name: "Ring Nebula",           raDeg: 283.396, decDeg: 33.029, magnitude: 8.8, type: .planetary),
    MessierObject(id: "M76", name: "Little Dumbbell",       raDeg: 25.582, decDeg: 51.575, magnitude: 10.1, type: .planetary),
    MessierObject(id: "M78", name: "Reflection Nebula",     raDeg: 86.691, decDeg: 0.079, magnitude: 8.3, type: .nebula),
    MessierObject(id: "M97", name: "Owl Nebula",            raDeg: 168.699, decDeg: 55.019, magnitude: 9.9, type: .planetary),

    // Globular Clusters
    MessierObject(id: "M2",  name: "Aquarius Globular",     raDeg: 323.363, decDeg: -0.823, magnitude: 6.5, type: .globular),
    MessierObject(id: "M3",  name: "Canes Venatici Glob.",  raDeg: 205.548, decDeg: 28.377, magnitude: 6.2, type: .globular),
    MessierObject(id: "M4",  name: "Scorpius Globular",     raDeg: 245.897, decDeg: -26.526, magnitude: 5.6, type: .globular),
    MessierObject(id: "M5",  name: "Serpens Globular",      raDeg: 229.638, decDeg: 2.081, magnitude: 5.6, type: .globular),
    MessierObject(id: "M9",  name: "Ophiuchus Globular",    raDeg: 259.800, decDeg: -18.516, magnitude: 7.7, type: .globular),
    MessierObject(id: "M10", name: "Ophiuchus Globular",    raDeg: 254.288, decDeg: -4.100, magnitude: 6.6, type: .globular),
    MessierObject(id: "M12", name: "Gumball Globular",      raDeg: 251.810, decDeg: -1.949, magnitude: 6.7, type: .globular),
    MessierObject(id: "M13", name: "Hercules Cluster",      raDeg: 250.423, decDeg: 36.461, magnitude: 5.8, type: .globular),
    MessierObject(id: "M14", name: "Ophiuchus Globular",    raDeg: 264.400, decDeg: -3.246, magnitude: 7.6, type: .globular),
    MessierObject(id: "M15", name: "Pegasus Globular",      raDeg: 322.493, decDeg: 12.167, magnitude: 6.2, type: .globular),
    MessierObject(id: "M19", name: "Ophiuchus Globular",    raDeg: 255.657, decDeg: -26.268, magnitude: 6.8, type: .globular),
    MessierObject(id: "M22", name: "Sagittarius Globular",  raDeg: 279.100, decDeg: -23.905, magnitude: 5.1, type: .globular),
    MessierObject(id: "M28", name: "Sagittarius Globular",  raDeg: 276.137, decDeg: -24.870, magnitude: 6.8, type: .globular),
    MessierObject(id: "M30", name: "Capricornus Globular",  raDeg: 325.092, decDeg: -23.180, magnitude: 7.2, type: .globular),
    MessierObject(id: "M53", name: "Coma Berenices Glob.",  raDeg: 198.230, decDeg: 18.169, magnitude: 7.6, type: .globular),
    MessierObject(id: "M54", name: "Sagittarius Globular",  raDeg: 283.764, decDeg: -30.480, magnitude: 7.6, type: .globular),
    MessierObject(id: "M55", name: "Summer Rose Star",      raDeg: 294.999, decDeg: -30.965, magnitude: 6.3, type: .globular),
    MessierObject(id: "M56", name: "Lyra Globular",         raDeg: 289.148, decDeg: 30.184, magnitude: 8.3, type: .globular),
    MessierObject(id: "M62", name: "Ophiuchus Globular",    raDeg: 255.303, decDeg: -30.114, magnitude: 6.5, type: .globular),
    MessierObject(id: "M68", name: "Hydra Globular",        raDeg: 189.867, decDeg: -26.744, magnitude: 7.8, type: .globular),
    MessierObject(id: "M69", name: "Sagittarius Globular",  raDeg: 277.846, decDeg: -32.348, magnitude: 7.6, type: .globular),
    MessierObject(id: "M70", name: "Sagittarius Globular",  raDeg: 278.779, decDeg: -32.301, magnitude: 7.9, type: .globular),
    MessierObject(id: "M71", name: "Sagitta Globular",      raDeg: 298.444, decDeg: 18.779, magnitude: 8.2, type: .globular),
    MessierObject(id: "M72", name: "Aquarius Globular",     raDeg: 313.365, decDeg: -12.537, magnitude: 9.3, type: .globular),
    MessierObject(id: "M75", name: "Sagittarius Globular",  raDeg: 301.520, decDeg: -21.921, magnitude: 8.5, type: .globular),
    MessierObject(id: "M79", name: "Lepus Globular",        raDeg: 81.046, decDeg: -24.524, magnitude: 7.7, type: .globular),
    MessierObject(id: "M80", name: "Scorpius Globular",     raDeg: 244.260, decDeg: -22.976, magnitude: 7.3, type: .globular),
    MessierObject(id: "M92", name: "Hercules Globular",     raDeg: 259.281, decDeg: 43.136, magnitude: 6.4, type: .globular),
    MessierObject(id: "M107", name: "Ophiuchus Globular",   raDeg: 248.133, decDeg: -13.054, magnitude: 7.9, type: .globular),

    // Open Clusters
    MessierObject(id: "M6",  name: "Butterfly Cluster",     raDeg: 265.083, decDeg: -32.217, magnitude: 4.2, type: .cluster),
    MessierObject(id: "M7",  name: "Ptolemy Cluster",       raDeg: 268.467, decDeg: -34.793, magnitude: 3.3, type: .cluster),
    MessierObject(id: "M11", name: "Wild Duck Cluster",     raDeg: 282.765, decDeg: -6.271, magnitude: 5.8, type: .cluster),
    MessierObject(id: "M18", name: "Sagittarius Cluster",   raDeg: 275.238, decDeg: -17.130, magnitude: 6.9, type: .cluster),
    MessierObject(id: "M21", name: "Sagittarius Cluster",   raDeg: 270.978, decDeg: -22.500, magnitude: 5.9, type: .cluster),
    MessierObject(id: "M23", name: "Sagittarius Cluster",   raDeg: 269.267, decDeg: -19.017, magnitude: 5.5, type: .cluster),
    MessierObject(id: "M25", name: "IC 4725",               raDeg: 277.922, decDeg: -19.115, magnitude: 4.6, type: .cluster),
    MessierObject(id: "M26", name: "Scutum Cluster",        raDeg: 281.317, decDeg: -9.383, magnitude: 8.0, type: .cluster),
    MessierObject(id: "M29", name: "Cygnus Cluster",        raDeg: 305.967, decDeg: 38.517, magnitude: 6.6, type: .cluster),
    MessierObject(id: "M34", name: "Perseus Cluster",       raDeg: 40.517, decDeg: 42.783, magnitude: 5.2, type: .cluster),
    MessierObject(id: "M35", name: "Gemini Cluster",        raDeg: 92.250, decDeg: 24.333, magnitude: 5.1, type: .cluster),
    MessierObject(id: "M36", name: "Pinwheel Cluster",      raDeg: 84.083, decDeg: 34.133, magnitude: 6.0, type: .cluster),
    MessierObject(id: "M37", name: "Auriga Cluster",        raDeg: 88.067, decDeg: 32.550, magnitude: 5.6, type: .cluster),
    MessierObject(id: "M38", name: "Starfish Cluster",      raDeg: 82.167, decDeg: 35.850, magnitude: 6.4, type: .cluster),
    MessierObject(id: "M39", name: "Cygnus Cluster",        raDeg: 322.317, decDeg: 48.433, magnitude: 4.6, type: .cluster),
    MessierObject(id: "M41", name: "Canis Major Cluster",   raDeg: 101.500, decDeg: -20.733, magnitude: 4.5, type: .cluster),
    MessierObject(id: "M44", name: "Beehive Cluster",       raDeg: 130.025, decDeg: 19.667, magnitude: 3.1, type: .cluster),
    MessierObject(id: "M45", name: "Pleiades",              raDeg: 56.750, decDeg: 24.117, magnitude: 1.6, type: .cluster),
    MessierObject(id: "M46", name: "Puppis Cluster",        raDeg: 115.383, decDeg: -14.817, magnitude: 6.1, type: .cluster),
    MessierObject(id: "M47", name: "Puppis Cluster",        raDeg: 114.150, decDeg: -14.500, magnitude: 4.4, type: .cluster),
    MessierObject(id: "M48", name: "Hydra Cluster",         raDeg: 123.433, decDeg: -5.800, magnitude: 5.8, type: .cluster),
    MessierObject(id: "M50", name: "Monoceros Cluster",     raDeg: 105.683, decDeg: -8.333, magnitude: 5.9, type: .cluster),
    MessierObject(id: "M52", name: "Cassiopeia Cluster",    raDeg: 351.200, decDeg: 61.583, magnitude: 6.9, type: .cluster),
    MessierObject(id: "M67", name: "Cancer Cluster",        raDeg: 132.825, decDeg: 11.817, magnitude: 6.9, type: .cluster),
    MessierObject(id: "M73", name: "Aquarius Asterism",     raDeg: 314.750, decDeg: -12.633, magnitude: 9.0, type: .cluster),
    MessierObject(id: "M93", name: "Puppis Cluster",        raDeg: 116.150, decDeg: -23.867, magnitude: 6.2, type: .cluster),
    MessierObject(id: "M103", name: "Cassiopeia Cluster",   raDeg: 23.350, decDeg: 60.650, magnitude: 7.4, type: .cluster),

    // Galaxies
    MessierObject(id: "M31", name: "Andromeda Galaxy",      raDeg: 10.685, decDeg: 41.269, magnitude: 3.4, type: .galaxy),
    MessierObject(id: "M32", name: "Andromeda Companion",   raDeg: 10.674, decDeg: 40.865, magnitude: 8.1, type: .galaxy),
    MessierObject(id: "M33", name: "Triangulum Galaxy",     raDeg: 23.462, decDeg: 30.660, magnitude: 5.7, type: .galaxy),
    MessierObject(id: "M49", name: "Virgo Galaxy",          raDeg: 187.445, decDeg: 8.000, magnitude: 8.4, type: .galaxy),
    MessierObject(id: "M51", name: "Whirlpool Galaxy",      raDeg: 202.470, decDeg: 47.195, magnitude: 8.4, type: .galaxy),
    MessierObject(id: "M58", name: "Virgo Galaxy",          raDeg: 189.431, decDeg: 11.818, magnitude: 9.7, type: .galaxy),
    MessierObject(id: "M59", name: "Virgo Galaxy",          raDeg: 190.509, decDeg: 11.647, magnitude: 9.6, type: .galaxy),
    MessierObject(id: "M60", name: "Virgo Galaxy",          raDeg: 190.917, decDeg: 11.553, magnitude: 8.8, type: .galaxy),
    MessierObject(id: "M61", name: "Virgo Galaxy",          raDeg: 185.479, decDeg: 4.474, magnitude: 9.7, type: .galaxy),
    MessierObject(id: "M63", name: "Sunflower Galaxy",      raDeg: 198.955, decDeg: 42.029, magnitude: 8.6, type: .galaxy),
    MessierObject(id: "M64", name: "Black Eye Galaxy",      raDeg: 194.182, decDeg: 21.683, magnitude: 8.5, type: .galaxy),
    MessierObject(id: "M65", name: "Leo Triplet",           raDeg: 169.733, decDeg: 13.092, magnitude: 9.3, type: .galaxy),
    MessierObject(id: "M66", name: "Leo Triplet",           raDeg: 170.063, decDeg: 12.992, magnitude: 8.9, type: .galaxy),
    MessierObject(id: "M74", name: "Phantom Galaxy",        raDeg: 24.174, decDeg: 15.783, magnitude: 9.4, type: .galaxy),
    MessierObject(id: "M77", name: "Cetus A",               raDeg: 40.670, decDeg: -0.014, magnitude: 8.9, type: .galaxy),
    MessierObject(id: "M81", name: "Bode's Galaxy",         raDeg: 148.888, decDeg: 69.065, magnitude: 6.9, type: .galaxy),
    MessierObject(id: "M82", name: "Cigar Galaxy",          raDeg: 148.970, decDeg: 69.680, magnitude: 8.4, type: .galaxy),
    MessierObject(id: "M83", name: "Southern Pinwheel",     raDeg: 204.254, decDeg: -29.865, magnitude: 7.6, type: .galaxy),
    MessierObject(id: "M84", name: "Virgo Galaxy",          raDeg: 186.265, decDeg: 12.887, magnitude: 9.1, type: .galaxy),
    MessierObject(id: "M85", name: "Coma Galaxy",           raDeg: 186.350, decDeg: 18.191, magnitude: 9.1, type: .galaxy),
    MessierObject(id: "M86", name: "Virgo Galaxy",          raDeg: 186.549, decDeg: 12.946, magnitude: 8.9, type: .galaxy),
    MessierObject(id: "M87", name: "Virgo A",               raDeg: 187.706, decDeg: 12.391, magnitude: 8.6, type: .galaxy),
    MessierObject(id: "M88", name: "Coma Galaxy",           raDeg: 187.997, decDeg: 14.420, magnitude: 9.6, type: .galaxy),
    MessierObject(id: "M89", name: "Virgo Galaxy",          raDeg: 188.916, decDeg: 12.556, magnitude: 9.8, type: .galaxy),
    MessierObject(id: "M90", name: "Virgo Galaxy",          raDeg: 189.209, decDeg: 13.163, magnitude: 9.5, type: .galaxy),
    MessierObject(id: "M91", name: "Coma Galaxy",           raDeg: 188.860, decDeg: 14.497, magnitude: 10.2, type: .galaxy),
    MessierObject(id: "M94", name: "Cat's Eye Galaxy",      raDeg: 192.722, decDeg: 41.120, magnitude: 8.2, type: .galaxy),
    MessierObject(id: "M95", name: "Leo Galaxy",            raDeg: 160.990, decDeg: 11.704, magnitude: 9.7, type: .galaxy),
    MessierObject(id: "M96", name: "Leo Galaxy",            raDeg: 161.693, decDeg: 11.820, magnitude: 9.2, type: .galaxy),
    MessierObject(id: "M98", name: "Coma Galaxy",           raDeg: 183.451, decDeg: 14.900, magnitude: 10.1, type: .galaxy),
    MessierObject(id: "M99", name: "Coma Pinwheel",         raDeg: 184.707, decDeg: 14.417, magnitude: 9.9, type: .galaxy),
    MessierObject(id: "M100", name: "Mirror Galaxy",        raDeg: 185.729, decDeg: 15.822, magnitude: 9.3, type: .galaxy),
    MessierObject(id: "M101", name: "Pinwheel Galaxy",      raDeg: 210.802, decDeg: 54.349, magnitude: 7.9, type: .galaxy),
    MessierObject(id: "M104", name: "Sombrero Galaxy",      raDeg: 190.010, decDeg: -11.623, magnitude: 8.0, type: .galaxy),
    MessierObject(id: "M105", name: "Leo Galaxy",           raDeg: 161.957, decDeg: 12.582, magnitude: 9.3, type: .galaxy),
    MessierObject(id: "M106", name: "Canes Venatici Gal.",  raDeg: 184.740, decDeg: 47.304, magnitude: 8.4, type: .galaxy),
    MessierObject(id: "M108", name: "Surfboard Galaxy",     raDeg: 167.879, decDeg: 55.674, magnitude: 10.0, type: .galaxy),
    MessierObject(id: "M109", name: "Vacuum Cleaner Gal.",  raDeg: 179.400, decDeg: 53.375, magnitude: 9.8, type: .galaxy),
    MessierObject(id: "M110", name: "Andromeda Companion",  raDeg: 10.092, decDeg: 41.685, magnitude: 8.5, type: .galaxy),
]
