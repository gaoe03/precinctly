"""Loader for NY VTD geometry from Census TIGER/Line 2020 (TIGER2020PL release).

Source: public_data/tl_2020_36_vtd20/  (statewide NY VTD shapefile, EPSG:4269 lon/lat).
Download URL (the TIGER2020/VTD path is a 404 — VTDs live under the PL release):
  https://www2.census.gov/geo/tiger/TIGER2020PL/LAYER/VTD/2020/tl_2020_36_vtd20.zip

Returns {GEOID20: {"geometry": shapely_geom,        # NAD83 lon/lat (EPSG:4269)
                   "name": NAME20,                  # str (raw; '1' or '000024')
                   "county_fips": STATEFP20+COUNTYFP20,  # 5-char, e.g. '36061'
                   "aland_sqmi": ALAND20 / sq-m-per-sq-mi}}
GEOID20 is the 11-char string join key (state 36 + county FIPS + VTD code).
"""
import os
import shapefile  # pyshp 3.x ('pip3 install pyshp') — pure Python, no GDAL
from shapely.geometry import shape as shapely_shape

_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "public_data")
NY_VTD_SHP = os.path.join(_DIR, "tl_2020_36_vtd20", "tl_2020_36_vtd20")
SQM_PER_SQMI = 2589988.110336  # exact: 1 sq mi in square metres


def load_geometry_ny(shp_path=NY_VTD_SHP):
    sf = shapefile.Reader(shp_path)
    out = {}
    for sr in sf.iterShapeRecords():
        rec = sr.record
        geoid = rec["GEOID20"]
        out[geoid] = {
            "geometry": shapely_shape(sr.shape.__geo_interface__),  # Polygon/MultiPolygon, holes ok
            "name": rec["NAME20"],
            "county_fips": rec["STATEFP20"] + rec["COUNTYFP20"],
            "aland_sqmi": rec["ALAND20"] / SQM_PER_SQMI,
        }
    return out


if __name__ == "__main__":
    geo = load_geometry_ny()
    print("NY VTD count:", len(geo))
    gid = "36061000001"
    print("sample", gid, "bounds:", geo[gid]["geometry"].bounds,
          "county:", geo[gid]["county_fips"], "aland_sqmi:", round(geo[gid]["aland_sqmi"], 5))
