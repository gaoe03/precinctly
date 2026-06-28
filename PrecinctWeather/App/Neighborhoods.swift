import Foundation

/// Offline search corpus: well-known places across the loaded states (NYC
/// neighborhoods + major CA & MA cities), each with a representative coordinate.
/// Tapping one jumps the map there and resolves that precinct.
/// (Fully on-device — no network geocoding, preserving the privacy posture.)
struct Neighborhood: Identifiable {
    let id = UUID()
    let name: String
    let borough: String     // region/borough label shown as the subtitle
    let lat: Double
    let lon: Double

    /// State inferred from the coordinate (clean separation for the curated list).
    var state: String {
        if lon < -114 { return "CA" }
        if lat > 41 && lon > -73.5 { return "MA" }
        return "NY"
    }
}

let searchPlaces: [Neighborhood] = [
    // Manhattan
    .init(name: "Financial District", borough: "Manhattan", lat: 40.707, lon: -74.011),
    .init(name: "Tribeca", borough: "Manhattan", lat: 40.716, lon: -74.009),
    .init(name: "Chinatown", borough: "Manhattan", lat: 40.716, lon: -73.997),
    .init(name: "Lower East Side", borough: "Manhattan", lat: 40.715, lon: -73.984),
    .init(name: "SoHo", borough: "Manhattan", lat: 40.723, lon: -74.002),
    .init(name: "Greenwich Village", borough: "Manhattan", lat: 40.733, lon: -74.002),
    .init(name: "East Village", borough: "Manhattan", lat: 40.727, lon: -73.982),
    .init(name: "Chelsea", borough: "Manhattan", lat: 40.746, lon: -74.001),
    .init(name: "Gramercy", borough: "Manhattan", lat: 40.737, lon: -73.986),
    .init(name: "Murray Hill", borough: "Manhattan", lat: 40.748, lon: -73.978),
    .init(name: "Midtown", borough: "Manhattan", lat: 40.754, lon: -73.984),
    .init(name: "Times Square", borough: "Manhattan", lat: 40.758, lon: -73.985),
    .init(name: "Hell's Kitchen", borough: "Manhattan", lat: 40.764, lon: -73.991),
    .init(name: "Upper East Side", borough: "Manhattan", lat: 40.773, lon: -73.956),
    .init(name: "Upper West Side", borough: "Manhattan", lat: 40.787, lon: -73.975),
    .init(name: "Morningside Heights", borough: "Manhattan", lat: 40.808, lon: -73.963),
    .init(name: "Harlem", borough: "Manhattan", lat: 40.811, lon: -73.946),
    .init(name: "East Harlem", borough: "Manhattan", lat: 40.795, lon: -73.939),
    .init(name: "Washington Heights", borough: "Manhattan", lat: 40.840, lon: -73.940),
    .init(name: "Inwood", borough: "Manhattan", lat: 40.867, lon: -73.921),
    // Brooklyn
    .init(name: "Greenpoint", borough: "Brooklyn", lat: 40.730, lon: -73.951),
    .init(name: "Williamsburg", borough: "Brooklyn", lat: 40.708, lon: -73.957),
    .init(name: "Bushwick", borough: "Brooklyn", lat: 40.694, lon: -73.921),
    .init(name: "Bedford-Stuyvesant", borough: "Brooklyn", lat: 40.687, lon: -73.941),
    .init(name: "Crown Heights", borough: "Brooklyn", lat: 40.668, lon: -73.943),
    .init(name: "Fort Greene", borough: "Brooklyn", lat: 40.690, lon: -73.974),
    .init(name: "Brooklyn Heights", borough: "Brooklyn", lat: 40.696, lon: -73.993),
    .init(name: "DUMBO", borough: "Brooklyn", lat: 40.703, lon: -73.989),
    .init(name: "Park Slope", borough: "Brooklyn", lat: 40.671, lon: -73.978),
    .init(name: "Prospect Heights", borough: "Brooklyn", lat: 40.677, lon: -73.968),
    .init(name: "Carroll Gardens", borough: "Brooklyn", lat: 40.680, lon: -73.999),
    .init(name: "Red Hook", borough: "Brooklyn", lat: 40.677, lon: -74.011),
    .init(name: "Sunset Park", borough: "Brooklyn", lat: 40.655, lon: -74.010),
    .init(name: "Bay Ridge", borough: "Brooklyn", lat: 40.625, lon: -74.030),
    .init(name: "Bensonhurst", borough: "Brooklyn", lat: 40.602, lon: -73.994),
    .init(name: "Borough Park", borough: "Brooklyn", lat: 40.633, lon: -73.990),
    .init(name: "Flatbush", borough: "Brooklyn", lat: 40.654, lon: -73.959),
    .init(name: "Midwood", borough: "Brooklyn", lat: 40.620, lon: -73.961),
    .init(name: "Sheepshead Bay", borough: "Brooklyn", lat: 40.586, lon: -73.945),
    .init(name: "Coney Island", borough: "Brooklyn", lat: 40.575, lon: -73.979),
    .init(name: "Brighton Beach", borough: "Brooklyn", lat: 40.578, lon: -73.961),
    .init(name: "Brownsville", borough: "Brooklyn", lat: 40.665, lon: -73.910),
    .init(name: "East New York", borough: "Brooklyn", lat: 40.667, lon: -73.882),
    .init(name: "Canarsie", borough: "Brooklyn", lat: 40.640, lon: -73.901),
    // Queens
    .init(name: "Astoria", borough: "Queens", lat: 40.764, lon: -73.923),
    .init(name: "Long Island City", borough: "Queens", lat: 40.745, lon: -73.949),
    .init(name: "Sunnyside", borough: "Queens", lat: 40.743, lon: -73.920),
    .init(name: "Woodside", borough: "Queens", lat: 40.745, lon: -73.905),
    .init(name: "Jackson Heights", borough: "Queens", lat: 40.748, lon: -73.889),
    .init(name: "Elmhurst", borough: "Queens", lat: 40.737, lon: -73.880),
    .init(name: "Corona", borough: "Queens", lat: 40.748, lon: -73.862),
    .init(name: "Flushing", borough: "Queens", lat: 40.759, lon: -73.830),
    .init(name: "Forest Hills", borough: "Queens", lat: 40.718, lon: -73.846),
    .init(name: "Rego Park", borough: "Queens", lat: 40.726, lon: -73.862),
    .init(name: "Ridgewood", borough: "Queens", lat: 40.700, lon: -73.905),
    .init(name: "Jamaica", borough: "Queens", lat: 40.702, lon: -73.789),
    .init(name: "Bayside", borough: "Queens", lat: 40.762, lon: -73.778),
    .init(name: "Howard Beach", borough: "Queens", lat: 40.657, lon: -73.842),
    .init(name: "Far Rockaway", borough: "Queens", lat: 40.605, lon: -73.755),
    // Bronx
    .init(name: "Mott Haven", borough: "Bronx", lat: 40.809, lon: -73.921),
    .init(name: "Hunts Point", borough: "Bronx", lat: 40.812, lon: -73.884),
    .init(name: "Concourse", borough: "Bronx", lat: 40.835, lon: -73.922),
    .init(name: "Morrisania", borough: "Bronx", lat: 40.829, lon: -73.907),
    .init(name: "Soundview", borough: "Bronx", lat: 40.823, lon: -73.866),
    .init(name: "Tremont", borough: "Bronx", lat: 40.847, lon: -73.890),
    .init(name: "Fordham", borough: "Bronx", lat: 40.861, lon: -73.898),
    .init(name: "Kingsbridge", borough: "Bronx", lat: 40.881, lon: -73.902),
    .init(name: "Riverdale", borough: "Bronx", lat: 40.890, lon: -73.912),
    .init(name: "Pelham Bay", borough: "Bronx", lat: 40.850, lon: -73.833),
    .init(name: "Throgs Neck", borough: "Bronx", lat: 40.818, lon: -73.819),
    .init(name: "Wakefield", borough: "Bronx", lat: 40.898, lon: -73.857),
    // Staten Island
    .init(name: "St. George", borough: "Staten Island", lat: 40.644, lon: -74.078),
    .init(name: "Stapleton", borough: "Staten Island", lat: 40.627, lon: -74.077),
    .init(name: "Port Richmond", borough: "Staten Island", lat: 40.633, lon: -74.137),
    .init(name: "South Beach", borough: "Staten Island", lat: 40.585, lon: -74.073),
    .init(name: "New Springville", borough: "Staten Island", lat: 40.585, lon: -74.165),
    .init(name: "Great Kills", borough: "Staten Island", lat: 40.554, lon: -74.151),
    .init(name: "Tottenville", borough: "Staten Island", lat: 40.512, lon: -74.246),
    // California
    .init(name: "Downtown LA", borough: "Los Angeles", lat: 34.050, lon: -118.243),
    .init(name: "Hollywood", borough: "Los Angeles", lat: 34.101, lon: -118.327),
    .init(name: "Santa Monica", borough: "Los Angeles", lat: 34.020, lon: -118.491),
    .init(name: "Beverly Hills", borough: "Los Angeles", lat: 34.073, lon: -118.400),
    .init(name: "Compton", borough: "Los Angeles", lat: 33.896, lon: -118.220),
    .init(name: "Long Beach", borough: "Los Angeles", lat: 33.770, lon: -118.189),
    .init(name: "Pasadena", borough: "Los Angeles", lat: 34.148, lon: -118.144),
    .init(name: "Anaheim", borough: "Orange County", lat: 33.836, lon: -117.914),
    .init(name: "Santa Ana", borough: "Orange County", lat: 33.746, lon: -117.868),
    .init(name: "Irvine", borough: "Orange County", lat: 33.685, lon: -117.826),
    .init(name: "San Diego", borough: "San Diego", lat: 32.716, lon: -117.161),
    .init(name: "Chula Vista", borough: "San Diego", lat: 32.640, lon: -117.084),
    .init(name: "Riverside", borough: "Inland Empire", lat: 33.953, lon: -117.396),
    .init(name: "Palm Springs", borough: "Riverside County", lat: 33.830, lon: -116.545),
    .init(name: "San Francisco", borough: "Bay Area", lat: 37.773, lon: -122.419),
    .init(name: "Mission District", borough: "San Francisco", lat: 37.760, lon: -122.414),
    .init(name: "Oakland", borough: "Bay Area", lat: 37.804, lon: -122.271),
    .init(name: "Berkeley", borough: "Bay Area", lat: 37.872, lon: -122.271),
    .init(name: "San Jose", borough: "Bay Area", lat: 37.339, lon: -121.895),
    .init(name: "Sacramento", borough: "Sacramento", lat: 38.582, lon: -121.494),
    .init(name: "Fresno", borough: "Central Valley", lat: 36.738, lon: -119.785),
    .init(name: "Bakersfield", borough: "Central Valley", lat: 35.373, lon: -119.019),
    .init(name: "Stockton", borough: "Central Valley", lat: 37.958, lon: -121.290),
    .init(name: "Santa Barbara", borough: "Santa Barbara", lat: 34.421, lon: -119.697),
    // Massachusetts
    .init(name: "Boston", borough: "Boston", lat: 42.360, lon: -71.058),
    .init(name: "Back Bay", borough: "Boston", lat: 42.350, lon: -71.081),
    .init(name: "Dorchester", borough: "Boston", lat: 42.300, lon: -71.066),
    .init(name: "Cambridge", borough: "Greater Boston", lat: 42.373, lon: -71.110),
    .init(name: "Somerville", borough: "Greater Boston", lat: 42.388, lon: -71.099),
    .init(name: "Brookline", borough: "Greater Boston", lat: 42.332, lon: -71.121),
    .init(name: "Newton", borough: "Greater Boston", lat: 42.337, lon: -71.209),
    .init(name: "Quincy", borough: "Greater Boston", lat: 42.253, lon: -71.002),
    .init(name: "Worcester", borough: "Massachusetts", lat: 42.263, lon: -71.802),
    .init(name: "Springfield", borough: "Massachusetts", lat: 42.101, lon: -72.590),
    .init(name: "Lowell", borough: "Massachusetts", lat: 42.633, lon: -71.316),
    .init(name: "Salem", borough: "Massachusetts", lat: 42.519, lon: -70.898),
]
