#!/usr/bin/env python3
"""Independently verify isolated OR/CO Phase 2B fallback candidates.

This verifier is intentionally separate from the builder. It recomputes the
candidate contract from the read-only private source, validates every retained
row and geometry, exercises app-shaped queries, and confirms that protected
shipping and hotfix files did not change.

Run from the repository root:

    python3 pipeline/phase2b_verify_candidate.py
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
from typing import Any, Iterable

from pyproj import Transformer
from shapely import make_valid, wkb, wkt
from shapely.geometry import GeometryCollection, MultiPolygon, Polygon
from shapely.ops import transform as geometry_transform
from shapely.ops import unary_union
from shapely.validation import explain_validity


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "precincts_2026_primary.db"
OUTPUT_DIR = ROOT / "public_data" / "phase2b_candidates"
PROTECTED_SNAPSHOT = OUTPUT_DIR / "protected_boundary_before.json"
DEFAULT_REPORT = OUTPUT_DIR / "verification_report.json"

PROTECTED_HASHES = {
    ".lavish/dmv-expansion.html": "c55ab8116b5af208b163d92c189497bc14c35bca018b1be7a4b8ddc6df332cc1",
    "PrecinctWeather/App/Screens/ContentView.swift": "551da6a0669a6217fe467a82fe0560dfdce1ae6c7d7dbd70e49503122454161a",
    "PrecinctWeather/App/Screens/ProfileSheet.swift": "b6b6f89d9bd72f37cb84a99cb1e0a5522f8b8a6e47bb7ee67fd01900a7d6bb21",
    "PrecinctWeather/App/Screens/SearchView.swift": "d1dab6d82b4ba096a294f206449790671f7d7c05efb02b28c35cbe333be0abc0",
    "PrecinctWeather/App/Support/LocationModel.swift": "de717b990a7c31f71c4002578fad4a38d2e90b9a84982bcc0cd7554a755b8ef3",
    "PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite": "69b69457cce78b6766ec85a725cdbe06a0f651a95234ed489205e2baed839284",
    "PrecinctWeather/PrecinctKit/Sources/PrecinctDB.swift": "d29ba0a9537832043b2008abccca93b969a3937f80891a5527c2a22daee8f150",
    "PrecinctWeather/PrecinctKit/Sources/WKBGeometry.swift": "deb54faf0d11541b8bbf94832f65b7c179f82cadfddf80197aead13b57d2de9b",
    "PrecinctWeather/PrecinctKit/Tests/PrecinctDBContractTests.swift": "b0e0c69246292f2b6fc8d501788e2a457cec0218bea95696bfc0963e5776d307",
    "PrecinctWeather/PrecinctKit/Tests/WKBGeometryTests.swift": "860f95d7a145fde0d752ceb9fd0c43467d3b73038d8fd60a033b39daacbcb644",
    "PrecinctWeather/UITests/ShareCardUITests.swift": "6e6995c3aca20fd26c57aed543c0627a438b053c4b26736576add8d5664f47ab",
    "PrecinctWeather/project.yml": "7f29e1e2d0257f1cc0e33b2c0460cae4db00c2a3a177d575b2e1773ce1731163",
    "nyc_precincts.sqlite": "a55f78ad7ee5ffa99eafef2d8f6921f448948fbc03cd367809d23b9d5fbb16cb",
    "precincts_2026_primary.db": "3c62500fd65c536adaa055d17f5075e238754d75a42e7cc10cf238e64119e684",
}

EXPECTED = {
    "OR": {
        "count": 1300,
        "counties": 36,
        "years": {2020: 1296, 2016: 1, None: 3},
        "null_units": {"41005-:-X000", "41027-:-XXXX", "41045-:-0019"},
        "repair_units": {
            "41007-:-0102", "41007-:-0105", "41009-:-0017",
            "41011-:-0007", "41041-:-0001", "41041-:-0011",
            "41065-:-0001",
        },
        "envelope": (-125.0, 41.5, -116.0, 47.0),
    },
    "CO": {
        "count": 3163,
        "counties": 64,
        "years": {2024: 3138, 2020: 21, None: 4},
        "null_units": {
            "08005-:-6276103288", "08005-:-4276103350",
            "08005-:-6283603359", "08035-:-4303918103",
        },
        "repair_units": set(),
        "envelope": (-110.0, 36.5, -101.0, 41.5),
    },
}

SOURCE_CRS = "EPSG:3857"
DESTINATION_CRS = "EPSG:4326"
SIMPLIFY_TOLERANCE = 0.00005
OFFICES = ("president", "senate", "governor")
RACE_VARIABLES = (
    "pop_white", "pop_black", "pop_hispanic", "pop_asian",
    "pop_native", "pop_pacific", "pop_other",
)
RACE_FIELDS = (
    "pct_white", "pct_black", "pct_hispanic", "pct_asian",
    "pct_native", "pct_pacific", "pct_other",
)
RACE_LABELS = (
    "White", "Black", "Hispanic", "Asian", "Native",
    "Pacific Islander", "Other",
)
EDUCATION_VARIABLES = (
    "edu_no_hs", "edu_hs", "edu_bachelors", "edu_graduate",
)
EDUCATION_FIELDS = (
    "pct_no_hs", "pct_hs", "pct_bachelors", "pct_graduate",
)
BASELINE_FIELDS = (
    "pct_white", "pct_black", "pct_hispanic", "pct_asian",
    "pct_native", "pct_pacific", "pct_other", "pct_ba_or_higher",
    "income_median", "pct_renter", "avg_age",
)
PERCENT_FIELDS = (*RACE_FIELDS, *EDUCATION_FIELDS, "pct_ba_or_higher", "pct_renter", "pct_owner")
REQUIRED_SOURCE_VARIABLES = {
    "pop_total", "vap_total", "cvap", "income_median", "pop_density",
    "avg_age", "housing_owner", "housing_renter", *RACE_VARIABLES,
    *EDUCATION_VARIABLES,
}
EXPECTED_TABLES = {
    "precincts", "precinct_elections", "baselines", "precinct_rtree",
    "county_lean_regions",
}
EXPECTED_COLUMNS = {
    "precincts": {
        "rowid", "unit_id", "fips", "state", "borough", "precinct_name",
        "min_lon", "min_lat", "max_lon", "max_lat", "geometry_wkb",
        "lean_dem_share", "prev_dem_share", "lean_year", "prev_year",
        "lean_label", "lean_shift", "lean_votes", "turnout_est", "pop_total",
        "vap_total", "cvap", *PERCENT_FIELDS, "plurality_group",
        "income_median", "pop_density", "avg_age", "data_complete",
    },
    "precinct_elections": {"unit_id", "office", "year", "dem", "rep", "other", "dem_share"},
    "baselines": {"scope", "precinct_count", "political_precinct_count", "pop_total", *BASELINE_FIELDS, "pres24_dem_share"},
    "precinct_rtree": {"id", "min_lon", "max_lon", "min_lat", "max_lat"},
    "county_lean_regions": {"rowid", "state", "borough", "lean_label", "dem_share", "min_lon", "min_lat", "max_lon", "max_lat", "geometry_wkb"},
}


class VerificationError(RuntimeError):
    """Raised when an artifact violates the authorized fallback contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def close_enough(actual: Any, expected: Any, tolerance: float = 1e-10) -> bool:
    if actual is None or expected is None:
        return actual is expected
    return math.isclose(float(actual), float(expected), rel_tol=tolerance, abs_tol=tolerance)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def connect_read_only(path: Path) -> sqlite3.Connection:
    require(path.is_file(), f"missing required file: {path}")
    connection = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    return connection


def parse_geometry(value: Any):
    if value is None:
        return None
    if isinstance(value, str):
        return wkt.loads(value)
    return wkb.loads(bytes(value))


def polygonal_only(geometry):
    if geometry.geom_type in {"Polygon", "MultiPolygon"}:
        return geometry
    if isinstance(geometry, GeometryCollection):
        pieces = [
            part for part in geometry.geoms
            if part.geom_type in {"Polygon", "MultiPolygon"} and not part.is_empty
        ]
        return unary_union(pieces) if pieces else None
    return None


def ratio(numerator: Any, denominator: Any):
    if numerator is None or denominator is None or denominator <= 0:
        return None
    return numerator / denominator


def expected_label(share: float | None) -> str | None:
    if share is None:
        return None
    if share >= 0.65:
        return "Solid Dem"
    if share >= 0.55:
        return "Lean Dem"
    if share >= 0.45:
        return "Even"
    if share >= 0.35:
        return "Lean Rep"
    return "Solid Rep"


def preferred_value(values: dict[str, dict[str, float | None]], variable: str):
    vintages = values.get(variable, {})
    prefix = "decennial" if variable in {*RACE_VARIABLES, "pop_total", "vap_total"} else "acs"
    matches = [(vintage, value) for vintage, value in vintages.items() if prefix in vintage]
    if matches:
        return sorted(matches)[0][1]
    return vintages[sorted(vintages)[0]] if vintages else None


def source_state(source: sqlite3.Connection, state: str):
    identity_rows = source.execute(
        """
        SELECT DISTINCT p.unit_id, p.fips, p.county, p.precinct_sos, p.geometry
        FROM precincts p
        JOIN demographics d ON d.unit_id=p.unit_id
        WHERE p.state_abbr=? AND d.variable='pop_total'
          AND d.vintage LIKE 'decennial%' AND d.value>0
        ORDER BY p.unit_id
        """,
        (state,),
    ).fetchall()
    grouped_identity: dict[str, set[tuple[Any, ...]]] = defaultdict(set)
    for row in identity_rows:
        grouped_identity[row[0]].add(tuple(row[1:]))
    ambiguous = {unit_id: rows for unit_id, rows in grouped_identity.items() if len(rows) != 1}
    require(not ambiguous, f"{state}: source has ambiguous retained identities: {sorted(ambiguous)[:5]}")
    identities = {row[0]: row for row in identity_rows}

    demographics: dict[str, dict[str, dict[str, float | None]]] = defaultdict(lambda: defaultdict(dict))
    elections: dict[str, dict[tuple[str, int], dict[str, int]]] = defaultdict(lambda: defaultdict(dict))
    unit_ids = sorted(identities)
    for start in range(0, len(unit_ids), 900):
        chunk = unit_ids[start:start + 900]
        marks = ",".join("?" for _ in chunk)
        for row in source.execute(
            f"SELECT unit_id,variable,value,vintage FROM demographics WHERE unit_id IN ({marks})",
            chunk,
        ):
            demographics[row[0]][row[1]][row[3]] = row[2]
        params = [*chunk, *OFFICES]
        office_marks = ",".join("?" for _ in OFFICES)
        for row in source.execute(
            f"""
            SELECT unit_id,race,year,party,SUM(votes)
            FROM election_results
            WHERE unit_id IN ({marks}) AND election_type='general'
              AND vote_type='total' AND race IN ({office_marks})
            GROUP BY unit_id,race,year,party
            """,
            params,
        ):
            require(row[4] is not None and row[4] >= 0, f"{state} {row[0]}: invalid source votes")
            elections[row[0]][(row[1], row[2])][row[3]] = row[4]
    return identities, demographics, elections


def usable_elections(unit_elections: dict[tuple[str, int], dict[str, int]]):
    usable = {}
    for key, parties in unit_elections.items():
        if "dem" not in parties or "rep" not in parties:
            continue
        if parties["dem"] + parties["rep"] <= 0:
            continue
        usable[key] = {
            "dem": parties["dem"],
            "rep": parties["rep"],
            "other": parties.get("other"),
            "dem_share": parties["dem"] / (parties["dem"] + parties["rep"]),
        }
    return usable


def verify_protected_boundary(snapshot_path: Path) -> dict[str, Any]:
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    require(snapshot.get("schema_version") == 1, "protected snapshot schema is unknown")
    require(snapshot.get("files") == PROTECTED_HASHES, "ignored protected snapshot differs from tracked verifier constants")
    mismatches = []
    for relative, expected_hash in sorted(PROTECTED_HASHES.items()):
        path = ROOT / relative
        actual = sha256(path) if path.is_file() else None
        if actual != expected_hash:
            mismatches.append({"path": relative, "expected": expected_hash, "actual": actual})
    require(not mismatches, f"protected boundary changed: {mismatches}")
    return {"file_count": len(PROTECTED_HASHES), "mismatch_count": 0}


def verify_schema(candidate: sqlite3.Connection, state: str) -> dict[str, Any]:
    integrity = candidate.execute("PRAGMA integrity_check").fetchone()[0]
    require(integrity == "ok", f"{state}: integrity_check returned {integrity!r}")
    tables = {
        row[0] for row in candidate.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }
    require(EXPECTED_TABLES <= tables, f"{state}: missing tables {sorted(EXPECTED_TABLES - tables)}")
    for table, required in EXPECTED_COLUMNS.items():
        columns = {row[1] for row in candidate.execute(f"PRAGMA table_info({table})")}
        require(required <= columns, f"{state}: {table} missing columns {sorted(required - columns)}")
    index_names = {
        row[0] for row in candidate.execute(
            "SELECT name FROM sqlite_master WHERE type='index'"
        )
    }
    required_indexes = {"idx_precincts_unit", "idx_precincts_state", "idx_pe_unit", "idx_clr_scope"}
    require(required_indexes <= index_names, f"{state}: missing indexes {sorted(required_indexes-index_names)}")
    return {"integrity_check": integrity, "tables": sorted(EXPECTED_TABLES), "indexes": sorted(required_indexes)}


def verify_source_and_rows(
    candidate: sqlite3.Connection,
    source: sqlite3.Connection,
    state: str,
) -> tuple[
    dict[str, Any],
    dict[int, Any],
    dict[str, dict[tuple[str, int], dict[str, int]]],
    dict[str, dict[str, float | None]],
    dict[str, dict[str, Any]],
]:
    contract = EXPECTED[state]
    identities, demographics, elections = source_state(source, state)
    rows = candidate.execute("SELECT * FROM precincts ORDER BY rowid").fetchall()
    by_unit = {row["unit_id"]: row for row in rows}
    require(len(rows) == contract["count"], f"{state}: expected {contract['count']} rows, found {len(rows)}")
    require(len(by_unit) == len(rows), f"{state}: duplicate candidate unit_id")
    require(set(by_unit) == set(identities), f"{state}: candidate unit set differs from positive-pop source")
    require({row["state"] for row in rows} == {state}, f"{state}: foreign state rows present")
    require(len({row["borough"] for row in rows}) == contract["counties"], f"{state}: county count mismatch")
    require(all(row["pop_total"] > 0 for row in rows), f"{state}: nonpositive population retained")

    transformer = Transformer.from_crs(SOURCE_CRS, DESTINATION_CRS, always_xy=True)
    candidate_geometries: dict[int, Any] = {}
    selected_years = Counter()
    source_invalid_units = set()
    expected_candidate_elections: dict[str, dict[tuple[str, int], dict[str, int]]] = {}
    baseline_weights: dict[str, dict[str, float | None]] = {}
    expected_repairs: dict[str, dict[str, Any]] = {}
    expected_nulls = contract["null_units"]
    null_demo_proof = []
    source_bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]
    output_bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]

    for row in rows:
        unit_id = row["unit_id"]
        source_row = identities[unit_id]
        require((row["fips"], row["borough"], row["precinct_name"]) == tuple(source_row[1:4]), f"{state} {unit_id}: identity mismatch")
        require(str(unit_id).startswith(str(row["fips"]) + "-:-"), f"{state} {unit_id}: unit_id and FIPS mismatch")
        require(str(row["fips"]).startswith("41" if state == "OR" else "08"), f"{state} {unit_id}: bad state FIPS")

        values = {variable: preferred_value(demographics[unit_id], variable) for variable in REQUIRED_SOURCE_VARIABLES}
        require(values["pop_total"] is not None and values["pop_total"] > 0, f"{state} {unit_id}: source population drift")
        pop = values["pop_total"]
        expected_fields = dict(zip(RACE_FIELDS, [ratio(values[name], pop) for name in RACE_VARIABLES]))
        education = [values[name] for name in EDUCATION_VARIABLES]
        education_total = sum(education) if all(value is not None for value in education) else None
        for field, value in zip(EDUCATION_FIELDS, education):
            expected_fields[field] = ratio(value, education_total)
        ba = (
            values["edu_bachelors"] + values["edu_graduate"]
            if education_total
            and values["edu_bachelors"] is not None
            and values["edu_graduate"] is not None
            else None
        )
        expected_fields["pct_ba_or_higher"] = ratio(ba, education_total)
        households = (
            values["housing_owner"] + values["housing_renter"]
            if values["housing_owner"] is not None and values["housing_renter"] is not None
            else None
        )
        baseline_weights[unit_id] = {
            "education_total": education_total,
            "household_total": households,
        }
        expected_fields["pct_renter"] = ratio(values["housing_renter"], households)
        expected_fields["pct_owner"] = ratio(values["housing_owner"], households)
        for field, expected_value in expected_fields.items():
            require(close_enough(row[field], expected_value), f"{state} {unit_id}: {field} source mismatch")
        for field in PERCENT_FIELDS:
            value = row[field]
            require(value is None or 0 <= value <= 1, f"{state} {unit_id}: {field} outside 0 through 1")

        available_races = [name for name in RACE_VARIABLES if values[name] is not None]
        expected_plurality = (
            RACE_LABELS[RACE_VARIABLES.index(max(available_races, key=lambda name: values[name]))]
            if available_races else None
        )
        require(row["plurality_group"] == expected_plurality, f"{state} {unit_id}: plurality mismatch")
        expected_income = None if values["income_median"] is None or values["income_median"] <= 0 else round(values["income_median"])
        expected_cvap = values["cvap"]
        if expected_cvap is not None and values["vap_total"] is not None:
            expected_cvap = min(expected_cvap, values["vap_total"])
        for field, expected_value in {
            "pop_total": int(pop),
            "vap_total": int(values["vap_total"]) if values["vap_total"] is not None else None,
            "cvap": int(expected_cvap) if expected_cvap is not None else None,
            "income_median": expected_income,
            "pop_density": values["pop_density"],
            "avg_age": values["avg_age"],
        }.items():
            require(close_enough(row[field], expected_value), f"{state} {unit_id}: {field} source mismatch")
        require(row["income_median"] is None or 0 < row["income_median"] <= 250001, f"{state} {unit_id}: income outside source contract")
        require(row["pop_density"] is None or row["pop_density"] >= 0, f"{state} {unit_id}: negative density")
        require(row["avg_age"] is None or 0 <= row["avg_age"] <= 100, f"{state} {unit_id}: implausible age")

        usable = usable_elections(elections[unit_id])
        president_years = sorted((year for office, year in usable if office == "president"), reverse=True)
        expected_year = president_years[0] if president_years else None
        if unit_id in expected_nulls:
            require(expected_year is None, f"{state} {unit_id}: expected null has a usable presidential year")
            usable = {}
        else:
            require(expected_year is not None, f"{state} {unit_id}: unexpected political null")
        expected_candidate_elections[unit_id] = usable
        selected = usable.get(("president", expected_year)) if expected_year else None
        prior_year = president_years[1] if len(president_years) > 1 else None
        prior = usable.get(("president", prior_year)) if prior_year else None
        selected_years[expected_year] += 1
        expected_lean_votes = None
        if selected:
            expected_lean_votes = selected["dem"] + selected["rep"]
            if selected["other"] is not None:
                expected_lean_votes += selected["other"]
        expected_turnout = ratio(expected_lean_votes, expected_cvap) if expected_cvap is not None and expected_cvap >= 50 else None
        if expected_turnout is not None and expected_turnout > 1.15:
            expected_turnout = None
        expected_political = {
            "lean_year": expected_year,
            "lean_dem_share": selected["dem_share"] if selected else None,
            "prev_year": prior_year,
            "prev_dem_share": prior["dem_share"] if prior else None,
            "lean_label": expected_label(selected["dem_share"] if selected else None),
            "lean_shift": selected["dem_share"] - prior["dem_share"] if selected and prior else None,
            "lean_votes": expected_lean_votes,
            "turnout_est": expected_turnout,
            "data_complete": 1 if selected else 0,
        }
        for field, expected_value in expected_political.items():
            require(close_enough(row[field], expected_value) if not isinstance(expected_value, str) else row[field] == expected_value, f"{state} {unit_id}: {field} political mismatch")
        if unit_id in expected_nulls:
            null_demo_proof.append(unit_id)
            require(row["geometry_wkb"] is not None and row["pop_total"] > 0, f"{state} {unit_id}: null profile lost geography or demographics")

        source_geometry = parse_geometry(source_row[4])
        require(source_geometry is not None and not source_geometry.is_empty, f"{state} {unit_id}: empty source geometry")
        original_geometry = source_geometry
        original_bounds = original_geometry.bounds
        source_bounds = [
            min(source_bounds[0], original_bounds[0]),
            min(source_bounds[1], original_bounds[1]),
            max(source_bounds[2], original_bounds[2]),
            max(source_bounds[3], original_bounds[3]),
        ]
        source_validity = explain_validity(original_geometry)
        if not original_geometry.is_valid:
            source_invalid_units.add(unit_id)
            source_geometry = polygonal_only(make_valid(original_geometry, method="linework", keep_collapsed=True))
        require(source_geometry is not None and source_geometry.is_valid, f"{state} {unit_id}: source repair failed")
        transformed_geometry = geometry_transform(transformer.transform, source_geometry)
        expected_geometry = transformed_geometry.simplify(SIMPLIFY_TOLERANCE, preserve_topology=True)
        candidate_geometry = parse_geometry(row["geometry_wkb"])
        require(candidate_geometry is not None and not candidate_geometry.is_empty, f"{state} {unit_id}: empty candidate geometry")
        require(candidate_geometry.geom_type in {"Polygon", "MultiPolygon"}, f"{state} {unit_id}: nonpolygon geometry")
        require(candidate_geometry.is_valid, f"{state} {unit_id}: invalid candidate geometry: {explain_validity(candidate_geometry)}")
        require(candidate_geometry.equals_exact(expected_geometry, 1e-12), f"{state} {unit_id}: geometry does not reproduce from source")
        require(all(close_enough(row[field], value, 1e-12) for field, value in zip(("min_lon", "min_lat", "max_lon", "max_lat"), candidate_geometry.bounds)), f"{state} {unit_id}: stored geometry bounds mismatch")
        candidate_geometries[row["rowid"]] = candidate_geometry
        candidate_bounds = candidate_geometry.bounds
        output_bounds = [
            min(output_bounds[0], candidate_bounds[0]),
            min(output_bounds[1], candidate_bounds[1]),
            max(output_bounds[2], candidate_bounds[2]),
            max(output_bounds[3], candidate_bounds[3]),
        ]
        if not original_geometry.is_valid:
            original_area = original_geometry.area
            repaired_area = source_geometry.area
            transformed_area = transformed_geometry.area
            expected_repairs[unit_id] = {
                "unit_id": unit_id,
                "source_valid": False,
                "source_validity": source_validity,
                "source_geometry_type": original_geometry.geom_type,
                "repaired_valid": source_geometry.is_valid,
                "repaired_validity": explain_validity(source_geometry),
                "repaired_geometry_type": source_geometry.geom_type,
                "source_area": original_area,
                "repaired_area": repaired_area,
                "source_repair_relative_area_drift_absolute": abs(repaired_area-original_area)/original_area if original_area else None,
                "source_repair_relative_area_drift_signed": (repaired_area-original_area)/original_area if original_area else None,
                "transformed_area_before_simplification": transformed_area,
                "simplified_area": candidate_geometry.area,
                "simplification_relative_area_drift_signed": (candidate_geometry.area-transformed_area)/transformed_area if transformed_area else None,
                "simplification_relative_area_drift_absolute": abs(candidate_geometry.area-transformed_area)/transformed_area if transformed_area else None,
                "simplified_valid": candidate_geometry.is_valid,
                "simplified_validity": explain_validity(candidate_geometry),
                "simplified_geometry_type": candidate_geometry.geom_type,
            }

    require(dict(selected_years) == contract["years"], f"{state}: selected year distribution {dict(selected_years)}")
    actual_nulls = {row["unit_id"] for row in rows if row["lean_year"] is None}
    require(actual_nulls == expected_nulls, f"{state}: null unit set mismatch")
    require(source_invalid_units == contract["repair_units"], f"{state}: source invalid set mismatch")
    return ({
        "precinct_count": len(rows),
        "county_count": len({row["borough"] for row in rows}),
        "selected_presidential_year_distribution": {"null" if key is None else str(key): value for key, value in sorted(selected_years.items(), key=lambda item: str(item[0]))},
        "null_units": sorted(actual_nulls),
        "null_profiles_with_geometry_and_demographics": sorted(null_demo_proof),
        "invalid_source_geometry_units": sorted(source_invalid_units),
        "source_bounds": source_bounds,
        "output_bounds": output_bounds,
    }, candidate_geometries, expected_candidate_elections, baseline_weights, expected_repairs)


def verify_election_table(
    candidate: sqlite3.Connection,
    state: str,
    expected_by_unit: dict[str, dict[tuple[str, int], dict[str, int]]],
) -> dict[str, Any]:
    actual = candidate.execute("SELECT * FROM precinct_elections ORDER BY unit_id,office,year").fetchall()
    actual_keys = set()
    missing_other_count = 0
    for row in actual:
        key = (row["unit_id"], row["office"], row["year"])
        require(key not in actual_keys, f"{state}: duplicate election row {key}")
        actual_keys.add(key)
        expected = expected_by_unit[row["unit_id"]].get((row["office"], row["year"]))
        require(expected is not None, f"{state}: unexpected election row {key}")
        for field in ("dem", "rep", "other", "dem_share"):
            require(close_enough(row[field], expected[field]), f"{state}: election mismatch {key} {field}")
        require(row["dem"] >= 0 and row["rep"] >= 0 and row["dem"] + row["rep"] > 0, f"{state}: unusable election emitted {key}")
        if expected["other"] is None:
            require(row["other"] is None, f"{state}: absent other votes were synthesized for {key}")
            missing_other_count += 1
    expected_keys = {
        (unit_id, office, year)
        for unit_id, elections in expected_by_unit.items()
        for office, year in elections
    }
    require(actual_keys == expected_keys, f"{state}: election row key set mismatch")
    return {"row_count": len(actual), "rows_with_unknown_other": missing_other_count}


def verify_rtree_and_lookup(candidate: sqlite3.Connection, state: str, geometries: dict[int, Any]) -> dict[str, Any]:
    rows = candidate.execute(
        """
        SELECT p.rowid,p.unit_id,p.data_complete,p.lean_dem_share,p.pop_total,
               p.min_lon,p.min_lat,p.max_lon,p.max_lat,
               r.min_lon AS rmin_lon,r.min_lat AS rmin_lat,
               r.max_lon AS rmax_lon,r.max_lat AS rmax_lat
        FROM precincts p LEFT JOIN precinct_rtree r ON r.id=p.rowid ORDER BY p.rowid
        """
    ).fetchall()
    require(len(rows) == len(geometries), f"{state}: R-tree join count mismatch")
    rtree_count = candidate.execute("SELECT COUNT(*) FROM precinct_rtree").fetchone()[0]
    require(rtree_count == len(rows), f"{state}: R-tree count mismatch")
    max_rounding = 0.0
    self_lookup_failures = []
    overlapping_representatives = 0
    for row in rows:
        require(row["rmin_lon"] is not None, f"{state} {row['unit_id']}: missing R-tree entry")
        require(row["rmin_lon"] <= row["min_lon"] and row["rmax_lon"] >= row["max_lon"] and row["rmin_lat"] <= row["min_lat"] and row["rmax_lat"] >= row["max_lat"], f"{state} {row['unit_id']}: R-tree does not conservatively contain exact bounds")
        max_rounding = max(max_rounding, *(abs(row[a] - row[b]) for a, b in (("rmin_lon", "min_lon"), ("rmax_lon", "max_lon"), ("rmin_lat", "min_lat"), ("rmax_lat", "max_lat"))))
        point = geometries[row["rowid"]].representative_point()
        candidates = candidate.execute(
            """
            SELECT p.rowid,p.unit_id FROM precinct_rtree r
            JOIN precincts p ON p.rowid=r.id
            WHERE ? BETWEEN r.min_lon AND r.max_lon AND ? BETWEEN r.min_lat AND r.max_lat
            ORDER BY p.data_complete DESC,(p.lean_dem_share IS NOT NULL) DESC,
                     (p.pop_total IS NOT NULL AND p.pop_total>0) DESC,
                     ((p.max_lon-p.min_lon)*(p.max_lat-p.min_lat)) ASC,r.id ASC
            """,
            (point.x, point.y),
        ).fetchall()
        containing = [entry for entry in candidates if geometries[entry["rowid"]].covers(point)]
        if len(containing) > 1:
            overlapping_representatives += 1
        if not containing or containing[0]["rowid"] != row["rowid"]:
            self_lookup_failures.append({"unit_id": row["unit_id"], "winner": containing[0]["unit_id"] if containing else None})
    require(max_rounding <= 0.00002, f"{state}: R-tree float rounding exceeds expected bound: {max_rounding}")
    require(not self_lookup_failures, f"{state}: representative-point lookup failures {self_lookup_failures[:5]}")
    return {"row_count": rtree_count, "max_outward_rounding_degrees": max_rounding, "representative_points_resolving_to_self": len(rows), "overlapping_representative_points": overlapping_representatives}


def verify_baselines(
    candidate: sqlite3.Connection,
    state: str,
    baseline_weights: dict[str, dict[str, float | None]],
) -> dict[str, Any]:
    precincts = candidate.execute("SELECT * FROM precincts ORDER BY unit_id").fetchall()
    elections = {
        (row["unit_id"], row["year"]): row
        for row in candidate.execute("SELECT * FROM precinct_elections WHERE office='president'")
    }
    scopes: dict[str, list[sqlite3.Row]] = defaultdict(list)
    for row in precincts:
        scopes[state].append(row)
        scopes[f"county|{state}|{row['borough']}"] .append(row)
    actual = {row["scope"]: row for row in candidate.execute("SELECT * FROM baselines")}
    require(set(actual) == set(scopes), f"{state}: baseline scope set mismatch")
    for scope, rows in scopes.items():
        baseline = actual[scope]
        require(baseline["precinct_count"] == len(rows), f"{state} {scope}: geographic precinct count mismatch")
        require(baseline["pop_total"] == sum(row["pop_total"] for row in rows), f"{state} {scope}: population mismatch")
        political = [row for row in rows if row["lean_year"] is not None]
        require(baseline["political_precinct_count"] == len(political), f"{state} {scope}: political count mismatch")
        dem = sum(elections[(row["unit_id"], row["lean_year"])]["dem"] for row in political)
        rep = sum(elections[(row["unit_id"], row["lean_year"])]["rep"] for row in political)
        expected_share = dem / (dem + rep) if dem + rep else None
        require(close_enough(baseline["pres24_dem_share"], expected_share), f"{state} {scope}: political baseline mismatch")
        for field in BASELINE_FIELDS:
            if field == "pct_ba_or_higher":
                weight_name = "education_total"
            elif field in {"income_median", "pct_renter"}:
                weight_name = "household_total"
            else:
                weight_name = "pop_total"
            valid = [
                row for row in rows
                if row[field] is not None
                and (field != "income_median" or row[field] > 0)
                and (
                    row["pop_total"] > 0 if weight_name == "pop_total"
                    else baseline_weights[row["unit_id"]][weight_name] is not None
                    and baseline_weights[row["unit_id"]][weight_name] > 0
                )
            ]
            def weight(row):
                return row["pop_total"] if weight_name == "pop_total" else baseline_weights[row["unit_id"]][weight_name]
            denominator = sum(weight(row) for row in valid)
            expected_value = sum(row[field] * weight(row) for row in valid) / denominator if denominator else None
            if field == "income_median" and expected_value is not None:
                expected_value = round(expected_value)
            require(close_enough(baseline[field], expected_value), f"{state} {scope}: {field} baseline mismatch")
    state_row = actual[state]
    return {"scope_count": len(actual), "county_scope_count": len(actual)-1, "state_geographic_precinct_count": state_row["precinct_count"], "state_political_precinct_count": state_row["political_precinct_count"], "state_selected_year_dem_share": state_row["pres24_dem_share"]}


def verify_regions(candidate: sqlite3.Connection, state: str, geometries: dict[int, Any]) -> dict[str, Any]:
    precincts = candidate.execute("SELECT rowid,unit_id,borough,lean_label,lean_year FROM precincts").fetchall()
    grouped: dict[tuple[str, str], list[sqlite3.Row]] = defaultdict(list)
    for row in precincts:
        grouped[(row["borough"], row["lean_label"] or "No data")].append(row)
    selected_votes = {
        (row["unit_id"], row["year"]): (row["dem"], row["rep"])
        for row in candidate.execute("SELECT unit_id,year,dem,rep FROM precinct_elections WHERE office='president'")
    }
    regions = candidate.execute("SELECT * FROM county_lean_regions ORDER BY rowid").fetchall()
    require(len(regions) == len(grouped), f"{state}: region bucket count mismatch")
    seen = set()
    no_data_count = 0
    for row in regions:
        key = (row["borough"], row["lean_label"])
        require(row["state"] == state and key in grouped and key not in seen, f"{state}: invalid or duplicate region bucket {key}")
        seen.add(key)
        members = grouped[key]
        if row["lean_label"] == "No data":
            require(row["dem_share"] is None, f"{state} {key}: no-data region has political share")
            require(all(member["lean_year"] is None for member in members), f"{state} {key}: no-data region has political member")
            no_data_count += 1
        else:
            votes = [selected_votes[(member["unit_id"], member["lean_year"])] for member in members]
            dem, rep = sum(value[0] for value in votes), sum(value[1] for value in votes)
            require(close_enough(row["dem_share"], dem/(dem+rep)), f"{state} {key}: region political share mismatch")
        geometry = parse_geometry(row["geometry_wkb"])
        require(geometry is not None and not geometry.is_empty and geometry.is_valid, f"{state} {key}: invalid region geometry")
        require(geometry.geom_type in {"Polygon", "MultiPolygon"}, f"{state} {key}: nonpolygon region geometry")
        require(all(close_enough(row[field], value, 1e-12) for field, value in zip(("min_lon", "min_lat", "max_lon", "max_lat"), geometry.bounds)), f"{state} {key}: region bounds mismatch")
        for member in members:
            require(geometry.buffer(2e-6).covers(geometries[member["rowid"]].representative_point()), f"{state} {key}: region does not cover member {member['unit_id']}")
    require(seen == set(grouped), f"{state}: missing region buckets")
    require(no_data_count > 0, f"{state}: expected no-data region missing")
    return {"region_count": len(regions), "no_data_region_count": no_data_count, "member_representative_points_covered": len(precincts)}


def verify_app_queries(candidate: sqlite3.Connection, state: str) -> dict[str, Any]:
    geographic = candidate.execute("SELECT COUNT(*) FROM precincts WHERE state=?", (state,)).fetchone()[0]
    political = candidate.execute("SELECT COUNT(*) FROM precincts WHERE state=? AND lean_dem_share IS NOT NULL", (state,)).fetchone()[0]
    null_count = candidate.execute("SELECT COUNT(*) FROM precincts WHERE state=? AND lean_dem_share IS NULL", (state,)).fetchone()[0]
    require(geographic == political + null_count, f"{state}: geographic and political populations do not partition")
    fake_even = candidate.execute("SELECT COUNT(*) FROM precincts WHERE lean_year IS NULL AND (lean_label='Even' OR lean_dem_share=0.5)").fetchone()[0]
    require(fake_even == 0, f"{state}: election-null profile was converted to Even")
    political_ranked_nulls = candidate.execute("SELECT COUNT(*) FROM precincts WHERE state=? AND lean_votes>=100 AND lean_dem_share IS NULL", (state,)).fetchone()[0]
    require(political_ranked_nulls == 0, f"{state}: political filter admits null profiles")
    political_range = candidate.execute(
        "SELECT MIN(lean_dem_share),MAX(lean_dem_share),AVG(lean_dem_share) FROM precincts WHERE state=? AND lean_votes>=100",
        (state,),
    ).fetchone()
    require(all(value is None or 0 <= value <= 1 for value in political_range), f"{state}: political range query is invalid")
    demographic_ranked = candidate.execute("SELECT unit_id FROM precincts WHERE state=? AND pop_total>=500 AND income_median IS NOT NULL ORDER BY income_median DESC,unit_id LIMIT 100", (state,)).fetchall()
    require(all(row[0] for row in demographic_ranked), f"{state}: demographic ranking returned malformed row")
    null_demo_rankable = candidate.execute("SELECT COUNT(*) FROM precincts WHERE state=? AND lean_year IS NULL AND pop_total>=500 AND income_median IS NOT NULL", (state,)).fetchone()[0]
    searchable_nulls = candidate.execute("SELECT COUNT(*) FROM precincts WHERE state=? AND lean_year IS NULL AND precinct_name IS NOT NULL", (state,)).fetchone()[0]
    require(searchable_nulls == null_count, f"{state}: an election-null profile is not name-searchable")
    return {"geographic_profiles": geographic, "political_profiles": political, "political_null_profiles": null_count, "political_filter_null_profiles": political_ranked_nulls, "political_range": list(political_range), "top_demographic_query_rows": len(demographic_ranked), "election_null_profiles_eligible_for_demographic_queries": null_demo_rankable, "election_null_profiles_name_searchable": searchable_nulls}


def verify_repair_ledger(
    path: Path,
    state: str,
    expected_repairs: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    document = json.loads(path.read_text(encoding="utf-8"))
    require(document.get("schema_version") == 1 and document.get("state") == state, f"{state}: repair ledger header mismatch")
    repairs = document.get("repairs", [])
    actual_units = {entry.get("unit_id") for entry in repairs}
    require(document.get("repair_count") == len(repairs), f"{state}: repair count mismatch")
    require(actual_units == EXPECTED[state]["repair_units"], f"{state}: repair unit set mismatch")
    require(actual_units == set(expected_repairs), f"{state}: repair ledger differs from source invalid set")
    max_repair_drift = 0.0
    max_simplify_drift = 0.0
    for entry in repairs:
        expected = expected_repairs[entry["unit_id"]]
        require(set(entry) == set(expected), f"{state} {entry['unit_id']}: repair ledger fields mismatch")
        for field, expected_value in expected.items():
            actual_value = entry[field]
            if isinstance(expected_value, float):
                require(close_enough(actual_value, expected_value, 1e-12), f"{state} {entry['unit_id']}: repair ledger {field} mismatch")
            else:
                require(actual_value == expected_value, f"{state} {entry['unit_id']}: repair ledger {field} mismatch")
        require(entry["source_valid"] is False and entry["repaired_valid"] is True and entry["simplified_valid"] is True, f"{state} {entry['unit_id']}: invalid repair status")
        require(entry["source_geometry_type"] in {"Polygon", "MultiPolygon"} and entry["simplified_geometry_type"] in {"Polygon", "MultiPolygon"}, f"{state} {entry['unit_id']}: repair type mismatch")
        repair_drift = entry["source_repair_relative_area_drift_absolute"]
        simplify_drift = entry["simplification_relative_area_drift_absolute"]
        require(repair_drift is not None and repair_drift <= 1e-6, f"{state} {entry['unit_id']}: repair area drift too large")
        require(simplify_drift is not None and simplify_drift <= 0.01, f"{state} {entry['unit_id']}: simplification area drift too large")
        max_repair_drift = max(max_repair_drift, repair_drift)
        max_simplify_drift = max(max_simplify_drift, simplify_drift)
    return {"repair_count": len(repairs), "repair_units": sorted(actual_units), "max_source_repair_relative_area_drift_absolute": max_repair_drift, "max_simplification_relative_area_drift_absolute": max_simplify_drift}


def verify_manifest(path: Path, database_path: Path, ledger_path: Path, state: str, source_hash: str, state_report: dict[str, Any]) -> dict[str, Any]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    require(manifest.get("schema_version") == 1, f"{state}: manifest schema mismatch")
    require(manifest.get("artifact_kind") == "phase2b_private_fallback_nonshipping_state_candidate", f"{state}: artifact kind mismatch")
    require(manifest.get("state") == state, f"{state}: manifest state mismatch")
    gate = manifest.get("release_gate", {})
    require(gate.get("status") == "BLOCKED" and gate.get("shipping_authorized") is False, f"{state}: release gate is not blocked")
    require("strict 2024 lineage gate remains blocked" in gate.get("reason", ""), f"{state}: manifest omits strict-lineage blocker")
    require(manifest["source"]["path"] == "precincts_2026_primary.db" and manifest["source"]["sha256"] == source_hash, f"{state}: source provenance mismatch")
    require(manifest["source"]["election_omission_zero_certifications"] == [], f"{state}: unexpected certified-zero claims")
    require(manifest["database"]["path"] == database_path.name and manifest["database"]["sha256"] == sha256(database_path) and manifest["database"]["size_bytes"] == database_path.stat().st_size, f"{state}: database identity mismatch")
    require(manifest["geometry"]["repair_ledger"] == ledger_path.name and manifest["geometry"]["invalid_source_count"] == state_report["geometry_repairs"]["repair_count"], f"{state}: geometry manifest mismatch")
    require(manifest["geometry"]["repair_ledger_sha256"] == sha256(ledger_path), f"{state}: repair ledger hash mismatch")
    selection = manifest["selection_contract"]
    require(selection["unit_count"] == EXPECTED[state]["count"], f"{state}: manifest unit count mismatch")
    require(set(selection["null_units"]) == EXPECTED[state]["null_units"], f"{state}: manifest null set mismatch")
    require(selection["selected_presidential_year_distribution"] == state_report["source_and_rows"]["selected_presidential_year_distribution"], f"{state}: manifest year distribution mismatch")
    require(selection["requires_dem_and_rep_rows"] is True and selection["requires_positive_two_party_total"] is True, f"{state}: manifest weakens election selection")
    require(selection["positive_population_only"] is True and selection["null_units_excluded_from_political_rows_and_aggregates"] is True, f"{state}: manifest weakens population or null policy")
    require(selection["null_units_keep_geometry_and_demographics"] is True and selection["older_history_requires_usable_dem_and_rep_rows"] is True, f"{state}: manifest weakens null retention or history policy")
    require(selection["lean_votes_rule"] == "Democratic plus Republican votes when other is absent and unknown. Democratic plus Republican plus other only when an other row is present. An absent other row remains NULL in precinct_elections and is never certified as zero.", f"{state}: manifest lean-vote rule mismatch")
    require(manifest["crs"]["source"] == SOURCE_CRS and manifest["crs"]["destination"] == DESTINATION_CRS, f"{state}: manifest CRS mismatch")
    require(all(close_enough(actual, expected, 1e-12) for actual, expected in zip(manifest["crs"]["source_bounds"], state_report["source_and_rows"]["source_bounds"])), f"{state}: manifest source bounds mismatch")
    output_bounds = manifest["crs"]["output_bounds"]
    require(all(close_enough(actual, expected, 1e-12) for actual, expected in zip(output_bounds, state_report["source_and_rows"]["output_bounds"])), f"{state}: manifest output bounds mismatch")
    env = EXPECTED[state]["envelope"]
    require(env[0] <= output_bounds[0] < output_bounds[2] <= env[2] and env[1] <= output_bounds[1] < output_bounds[3] <= env[3], f"{state}: manifest bounds outside state envelope")
    return {"path": str(path.relative_to(ROOT)), "sha256": sha256(path), "release_gate_status": gate["status"], "shipping_authorized": gate["shipping_authorized"]}


def verify_state(source: sqlite3.Connection, state: str) -> dict[str, Any]:
    prefix = state.lower()
    database_path = OUTPUT_DIR / f"{prefix}_fallback_candidate.sqlite"
    manifest_path = OUTPUT_DIR / f"{prefix}_manifest.json"
    ledger_path = OUTPUT_DIR / f"{prefix}_geometry_repairs.json"
    candidate = connect_read_only(database_path)
    try:
        report: dict[str, Any] = {"schema": verify_schema(candidate, state)}
        rows_report, geometries, expected_elections, baseline_weights, expected_repairs = verify_source_and_rows(candidate, source, state)
        report["source_and_rows"] = rows_report
        report["elections"] = verify_election_table(candidate, state, expected_elections)
        report["rtree_and_lookup"] = verify_rtree_and_lookup(candidate, state, geometries)
        report["baselines"] = verify_baselines(candidate, state, baseline_weights)
        report["lean_regions"] = verify_regions(candidate, state, geometries)
        report["app_shaped_queries"] = verify_app_queries(candidate, state)
        report["geometry_repairs"] = verify_repair_ledger(ledger_path, state, expected_repairs)
        report["database"] = {"path": str(database_path.relative_to(ROOT)), "size_bytes": database_path.stat().st_size, "sha256": sha256(database_path)}
        report["manifest"] = verify_manifest(manifest_path, database_path, ledger_path, state, sha256(SOURCE), report)
        return report
    finally:
        candidate.close()


def safe_report(raw: str) -> Path:
    path = Path(os.path.abspath(Path(raw).expanduser()))
    expected = Path(os.path.abspath(DEFAULT_REPORT))
    require(path == expected, f"report path must be {DEFAULT_REPORT}")
    require(not path.is_symlink() and not path.parent.is_symlink(), "verification report path cannot be a symlink")
    return path


def canonical_states(raw: str) -> tuple[str, str]:
    states = tuple(item.strip().upper() for item in raw.split(",") if item.strip())
    if len(states) != 2 or len(set(states)) != 2 or set(states) != set(EXPECTED):
        raise VerificationError("verification must cover the complete OR,CO candidate set")
    return ("OR", "CO")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--states", default="OR,CO", help="Complete candidate set. Must contain OR and CO")
    parser.add_argument("--report", default=str(DEFAULT_REPORT), type=safe_report)
    args = parser.parse_args()
    try:
        states = canonical_states(args.states)
    except VerificationError as error:
        parser.error(str(error))
    if Path.cwd().resolve() != ROOT:
        parser.error(f"run this script from the repository root: {ROOT}")

    report: dict[str, Any] = {
        "schema_version": 1,
        "artifact_kind": "phase2b_private_fallback_independent_verification",
        "result": "PASS",
        "contract": "Contract B latest usable general presidential result per private polygon",
        "release_gate": {
            "status": "BLOCKED",
            "shipping_authorized": False,
            "reason": "Official 2024 polygon lineage and affirmative redistribution and App Store bundling rights remain unverified.",
        },
        "source": {"path": str(SOURCE.relative_to(ROOT)), "sha256": sha256(SOURCE), "open_mode": "mode=ro, immutable=1, PRAGMA query_only=ON"},
        "protected_boundary": verify_protected_boundary(PROTECTED_SNAPSHOT),
        "states": {},
    }
    source = connect_read_only(SOURCE)
    try:
        for state in states:
            report["states"][state] = verify_state(source, state)
            print(f"{state}: PASS")
    finally:
        source.close()
    temporary_report = args.report.with_suffix(".json.tmp")
    require(not temporary_report.is_symlink(), "verification report staging path cannot be a symlink")
    temporary_report.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary_report.replace(args.report)
    print(f"verification report: {args.report}")
    print("PHASE 2B CANDIDATE VERIFICATION PASS")


if __name__ == "__main__":
    main()
