import Foundation
import SwiftAA

/// Static helpers for celestial calculations using SwiftAA.
/// Used by ConditionEvaluator for altitude-based sequence conditions.
enum SkyObjectsService {

    /// Sun altitude at the given moment.
    static func sunAltitude(lat: Double, lon: Double, date: Date = Date()) -> Double {
        let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
        let sun = Sun(julianDay: JulianDay(date))
        return sun.makeHorizontalCoordinates(with: geo).altitude.value
    }

    /// Moon altitude at the given moment.
    static func moonAltitude(lat: Double, lon: Double, date: Date = Date()) -> Double {
        let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
        let moon = Moon(julianDay: JulianDay(date))
        return moon.makeHorizontalCoordinates(with: geo).altitude.value
    }

    /// Moon illuminated fraction (0–1) at the given moment.
    static func moonIllumination(date: Date = Date()) -> Double {
        let moon = Moon(julianDay: JulianDay(date))
        return moon.illuminatedFraction()
    }

    /// Altitude of a celestial object at the given RA/Dec (degrees) and observer location.
    static func objectAltitude(raDeg: Double, decDeg: Double, lat: Double, lon: Double, date: Date = Date()) -> Double {
        let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
        let jd = JulianDay(date)
        let eq = EquatorialCoordinates(alpha: Hour(raDeg / 15.0), delta: Degree(decDeg))
        let horiz = eq.makeHorizontalCoordinates(for: geo, at: jd)
        return horiz.altitude.value
    }
}
