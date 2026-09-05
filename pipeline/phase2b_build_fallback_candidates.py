#!/usr/bin/env python3
"""Build isolated OR/CO fallback candidates from the private source artifact.

These are nonshipping release-evaluation candidates. They do not clear the Phase 2
official 2024 lineage and redistribution gate, and this script refuses to write
anywhere except public_data/phase2b_candidates.

Run from the repository root:

    python3 pipeline/phase2b_build_fallback_candidates.py
    python3 pipeline/phase2b_build_fallback_candidates.py --replace
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

from pyproj import Transformer
from shapely import make_valid, set_precision, wkb, wkt
from shapely.geometry import MultiPolygon, Polygon
from shapely.ops import transform as geometry_transform
from shapely.ops import unary_union
from shapely.validation import explain_validity

try:
    from pipeline.phase2b_aggregate_contract import (
        ElectionVote,
        PrecinctAggregateInput,
        compute_scope_baselines,
        select_latest_usable_president,
    )
except ModuleNotFoundError:
    from phase2b_aggregate_contract import (  # type: ignore[no-redef]
        ElectionVote,
        PrecinctAggregateInput,
        compute_scope_baselines,
        select_latest_usable_president,
    )


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "precincts_2026_primary.db"
SAFE_OUTPUT_DIR = ROOT / "public_data" / "phase2b_candidates"

STATES = ("OR", "CO")
STATE_NAMES = {"OR": "Oregon", "CO": "Colorado"}
EXPECTED_COUNTS = {
    "OR": {"total": 1300, "years": {2020: 1296, 2016: 1, None: 3}},
    "CO": {"total": 3163, "years": {2024: 3138, 2020: 21, None: 4}},
}
EXPECTED_NULL_UNITS = {
    "OR": {"41005-:-X000", "41027-:-XXXX", "41045-:-0019"},
    "CO": {
        "08005-:-6276103288",
        "08005-:-4276103350",
        "08005-:-6283603359",
        "08035-:-4303918103",
    },
}

# The private artifact stores OR and CO in Web Mercator coordinates. This is made
# explicit rather than inherited from build_region_precincts.py's generic fallback.
# The runtime proof gate below checks projected coordinate magnitude and requires the
# transformed aggregate bounds to land in a deliberately tight state envelope.
SOURCE_CRS = {"OR": "EPSG:3857", "CO": "EPSG:3857"}
STATE_ENVELOPES = {
    "OR": (-125.0, 41.5, -116.0, 47.0),
    "CO": (-110.0, 36.5, -101.0, 41.5),
}
DST_CRS = "EPSG:4326"
SIMPLIFY_TOLERANCE = 0.00005
REGION_GRID = 0.000001
MIN_HOLE_AREA = 0.0000001

OFFICES = ("president", "senate", "governor")
RACE_VARS = (
    "pop_white",
    "pop_black",
    "pop_hispanic",
    "pop_asian",
    "pop_native",
    "pop_pacific",
    "pop_other",
)
RACE_LABELS = {
    "pop_white": "White",
    "pop_black": "Black",
    "pop_hispanic": "Hispanic",
    "pop_asian": "Asian",
    "pop_native": "Native",
    "pop_pacific": "Pacific Islander",
    "pop_other": "Other",
}
EDU_VARS = ("edu_no_hs", "edu_hs", "edu_bachelors", "edu_graduate")
DECENNIAL_VARS = set(RACE_VARS) | {"pop_total", "vap_total"}
ACS_VARS = set(EDU_VARS) | {
    "cvap",
    "income_median",
    "pop_density",
    "avg_age",
    "housing_owner",
    "housing_renter",
}
ALL_VARS = DECENNIAL_VARS | ACS_VARS

SCHEMA = """
CREATE TABLE precincts (
  rowid INTEGER PRIMARY KEY,
  unit_id TEXT UNIQUE, fips TEXT, state TEXT, borough TEXT, precinct_name TEXT,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
  geometry_wkb BLOB,
  lean_dem_share REAL, prev_dem_share REAL, lean_year INT, prev_year INT,
  lean_label TEXT, lean_shift REAL, lean_votes INT, turnout_est REAL,
  pop_total INT, vap_total INT, cvap INT,
  pct_white REAL, pct_black REAL, pct_hispanic REAL, pct_asian REAL,
  pct_native REAL, pct_pacific REAL, pct_other REAL, plurality_group TEXT,
  pct_no_hs REAL, pct_hs REAL, pct_bachelors REAL, pct_graduate REAL,
  pct_ba_or_higher REAL, income_median INT, pop_density REAL, avg_age REAL,
  pct_renter REAL, pct_owner REAL, data_complete INT
);
CREATE INDEX idx_precincts_unit ON precincts(unit_id);
CREATE INDEX idx_precincts_state ON precincts(state, borough);

CREATE TABLE precinct_elections (
  unit_id TEXT, office TEXT, year INT, dem INT, rep INT, other INT,
  dem_share REAL
);
CREATE INDEX idx_pe_unit ON precinct_elections(unit_id);

CREATE TABLE baselines (
  scope TEXT PRIMARY KEY, precinct_count INT, political_precinct_count INT,
  pop_total INT,
  pct_white REAL, pct_black REAL, pct_hispanic REAL, pct_asian REAL,
  pct_native REAL, pct_pacific REAL, pct_other REAL,
  pct_ba_or_higher REAL, income_median INT, pct_renter REAL, avg_age REAL,
  pres24_dem_share REAL
);

CREATE VIRTUAL TABLE precinct_rtree USING rtree(
  id, min_lon, max_lon, min_lat, max_lat
);

CREATE TABLE county_lean_regions (
  rowid INTEGER PRIMARY KEY,
  state TEXT, borough TEXT, lean_label TEXT, dem_share REAL,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
  geometry_wkb BLOB
);
CREATE INDEX idx_clr_scope ON county_lean_regions(state, borough);
"""

PRECINCT_COLUMNS = (
    "rowid", "unit_id", "fips", "state", "borough", "precinct_name",
    "min_lon", "min_lat", "max_lon", "max_lat", "geometry_wkb",
    "lean_dem_share", "prev_dem_share", "lean_year", "prev_year",
    "lean_label", "lean_shift", "lean_votes", "turnout_est", "pop_total",
    "vap_total", "cvap", "pct_white", "pct_black", "pct_hispanic",
    "pct_asian", "pct_native", "pct_pacific", "pct_other",
    "plurality_group", "pct_no_hs", "pct_hs", "pct_bachelors",
    "pct_graduate", "pct_ba_or_higher", "income_median", "pop_density",
    "avg_age", "pct_renter", "pct_owner", "data_complete",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json_atomic(path: Path, document: dict[str, Any]) -> None:
    """Replace a candidate sidecar without exposing a partially written JSON file."""

    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def require_regular_or_missing(path: Path) -> None:
    if path.is_symlink():
        raise RuntimeError(f"refusing symlinked candidate path: {path}")
    if path.exists() and not path.is_file():
        raise RuntimeError(f"refusing non-file candidate path: {path}")


def install_artifact_set(
    staged_artifacts: list[tuple[Path, Path]],
    output_dir: Path,
) -> None:
    """Install a complete state bundle with rollback and the manifest as commit marker."""

    for staged, target in staged_artifacts:
        if staged.parent != output_dir or target.parent != output_dir:
            raise RuntimeError("candidate artifact escaped the guarded output directory")
        require_regular_or_missing(staged)
        require_regular_or_missing(target)
        if not staged.is_file():
            raise RuntimeError(f"missing staged candidate artifact: {staged}")

    rollback_dir = Path(tempfile.mkdtemp(prefix=".phase2b-rollback-", dir=output_dir))
    originals: dict[Path, Path] = {}
    installed: list[Path] = []
    try:
        for _, target in staged_artifacts:
            if target.exists():
                backup = rollback_dir / target.name
                shutil.copy2(target, backup)
                originals[target] = backup
        for staged, target in staged_artifacts:
            os.replace(staged, target)
            installed.append(target)
    except BaseException:
        for target in reversed(installed):
            backup = originals.get(target)
            if backup is not None and backup.exists():
                os.replace(backup, target)
            elif target.exists() and not target.is_symlink() and target.is_file():
                target.unlink()
        raise
    finally:
        shutil.rmtree(rollback_dir, ignore_errors=True)


def parse_geometry(raw: Any):
    if raw is None:
        return None
    if isinstance(raw, str):
        return wkt.loads(raw)
    return wkb.loads(bytes(raw))


def polygonal_only(geom):
    if geom.geom_type in ("Polygon", "MultiPolygon"):
        return geom
    if geom.geom_type == "GeometryCollection":
        polygonal = [
            part for part in geom.geoms
            if part.geom_type in ("Polygon", "MultiPolygon") and not part.is_empty
        ]
        return unary_union(polygonal) if polygonal else None
    return None


def fraction(numerator, denominator):
    if numerator is None or denominator is None or denominator <= 0:
        return None
    return numerator / denominator


def two_party(parties: dict[str, int | None]):
    dem = parties.get("dem")
    rep = parties.get("rep")
    if dem is None or rep is None or dem + rep <= 0:
        return None
    return dem / (dem + rep)


def lean_label(share):
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


def preferred_demo(values: dict[str, dict[str, float | None]], variable: str):
    vintages = values.get(variable, {})
    prefix = "decennial" if variable in DECENNIAL_VARS else "acs"
    for vintage in sorted(vintages):
        if prefix in vintage:
            return vintages[vintage]
    return vintages[sorted(vintages)[0]] if vintages else None


def chunks(values: list[str], size: int = 900) -> Iterable[list[str]]:
    for start in range(0, len(values), size):
        yield values[start:start + size]


def load_state(source: sqlite3.Connection, state: str):
    spine = source.execute(
        """
        SELECT DISTINCT p.unit_id, p.fips, p.county, p.precinct_sos, p.geometry
        FROM precincts p
        JOIN demographics d
          ON d.unit_id = p.unit_id
         AND d.variable = 'pop_total'
         AND d.vintage LIKE 'decennial%'
        WHERE p.state_abbr = ? AND d.value > 0
        ORDER BY p.unit_id
        """,
        (state,),
    ).fetchall()
    unit_ids = [row[0] for row in spine]

    raw_demographics = defaultdict(lambda: defaultdict(dict))
    raw_elections = defaultdict(lambda: defaultdict(dict))
    for unit_chunk in chunks(unit_ids):
        placeholders = ",".join("?" for _ in unit_chunk)
        for unit_id, variable, value, vintage in source.execute(
            f"""
            SELECT unit_id, variable, value, vintage
            FROM demographics
            WHERE unit_id IN ({placeholders})
            ORDER BY unit_id, variable, vintage
            """,
            unit_chunk,
        ):
            raw_demographics[unit_id][variable][vintage] = value

        params = list(unit_chunk) + list(OFFICES)
        office_placeholders = ",".join("?" for _ in OFFICES)
        for unit_id, office, year, party, votes in source.execute(
            f"""
            SELECT unit_id, race, year, party, SUM(votes)
            FROM election_results
            WHERE unit_id IN ({placeholders})
              AND election_type = 'general'
              AND vote_type = 'total'
              AND race IN ({office_placeholders})
            GROUP BY unit_id, race, year, party
            ORDER BY unit_id, race, year, party
            """,
            params,
        ):
            raw_elections[unit_id][(office, year)][party] = votes

    return spine, raw_demographics, raw_elections


def prepare_geometry(state, unit_id, raw_geometry, transformer, repair_ledger):
    source_geometry = parse_geometry(raw_geometry)
    if source_geometry is None or source_geometry.is_empty:
        raise RuntimeError(f"{state} {unit_id}: missing or empty source geometry")

    before_type = source_geometry.geom_type
    before_valid = source_geometry.is_valid
    before_reason = explain_validity(source_geometry)
    before_area = source_geometry.area
    repaired = source_geometry
    if not before_valid:
        repaired = polygonal_only(
            make_valid(source_geometry, method="linework", keep_collapsed=True)
        )
        if repaired is None or repaired.is_empty or not repaired.is_valid:
            raise RuntimeError(f"{state} {unit_id}: deterministic make_valid failed")

    after_area = repaired.area
    transformed = geometry_transform(transformer.transform, repaired)
    transformed_area = transformed.area
    simplified = transformed.simplify(SIMPLIFY_TOLERANCE, preserve_topology=True)
    if simplified.is_empty or not simplified.is_valid:
        simplified = polygonal_only(
            make_valid(simplified, method="linework", keep_collapsed=True)
        )
    if simplified is None or simplified.is_empty or not simplified.is_valid:
        raise RuntimeError(f"{state} {unit_id}: simplified geometry is unusable")

    if not before_valid:
        repair_ledger.append({
            "unit_id": unit_id,
            "source_valid": False,
            "source_validity": before_reason,
            "source_geometry_type": before_type,
            "repaired_valid": repaired.is_valid,
            "repaired_validity": explain_validity(repaired),
            "repaired_geometry_type": repaired.geom_type,
            "source_area": before_area,
            "repaired_area": after_area,
            "source_repair_relative_area_drift_absolute": (
                abs(after_area - before_area) / before_area if before_area else None
            ),
            "source_repair_relative_area_drift_signed": (
                (after_area - before_area) / before_area if before_area else None
            ),
            "transformed_area_before_simplification": transformed_area,
            "simplified_area": simplified.area,
            "simplification_relative_area_drift_signed": (
                (simplified.area - transformed_area) / transformed_area
                if transformed_area else None
            ),
            "simplification_relative_area_drift_absolute": (
                abs(simplified.area - transformed_area) / transformed_area
                if transformed_area else None
            ),
            "simplified_valid": simplified.is_valid,
            "simplified_validity": explain_validity(simplified),
            "simplified_geometry_type": simplified.geom_type,
        })
    return simplified


def clean_region(geometries):
    snapped = [set_precision(geometry, REGION_GRID) for geometry in geometries]
    merged = unary_union([geometry for geometry in snapped if not geometry.is_empty])
    polygons = (
        list(merged.geoms) if merged.geom_type == "MultiPolygon"
        else [merged] if merged.geom_type == "Polygon"
        else []
    )
    rebuilt = []
    for polygon in polygons:
        interiors = [
            ring.coords for ring in polygon.interiors
            if Polygon(ring).area >= MIN_HOLE_AREA
        ]
        rebuilt.append(Polygon(polygon.exterior.coords, interiors))
    if not rebuilt:
        raise RuntimeError("county lean region lost all polygonal area")
    result = rebuilt[0] if len(rebuilt) == 1 else MultiPolygon(rebuilt)
    if not result.is_valid:
        result = polygonal_only(
            make_valid(result, method="linework", keep_collapsed=True)
        )
    if result is None or result.is_empty or not result.is_valid:
        raise RuntimeError("county lean region is invalid after cleaning")
    return result


def validate_crs(state, source_bounds, output_bounds):
    if max(abs(value) for value in source_bounds) < 1_000_000:
        raise RuntimeError(f"{state}: coordinates do not prove projected Web Mercator input")
    min_lon, min_lat, max_lon, max_lat = output_bounds
    env_min_lon, env_min_lat, env_max_lon, env_max_lat = STATE_ENVELOPES[state]
    if not (
        env_min_lon <= min_lon < max_lon <= env_max_lon
        and env_min_lat <= min_lat < max_lat <= env_max_lat
    ):
        raise RuntimeError(
            f"{state}: EPSG:3857 transform produced out-of-envelope bounds {output_bounds}"
        )


def build_state(source, source_sha, state, output_dir, replace):
    db_path = output_dir / f"{state.lower()}_fallback_candidate.sqlite"
    manifest_path = output_dir / f"{state.lower()}_manifest.json"
    ledger_path = output_dir / f"{state.lower()}_geometry_repairs.json"
    targets = (db_path, manifest_path, ledger_path)
    existing = [path for path in targets if path.exists()]
    if existing and not replace:
        names = ", ".join(str(path) for path in existing)
        raise RuntimeError(f"refusing to replace existing outputs without --replace: {names}")

    spine, raw_demographics, raw_elections = load_state(source, state)
    expected = EXPECTED_COUNTS[state]
    if len(spine) != expected["total"]:
        raise RuntimeError(f"{state}: expected {expected['total']} units, found {len(spine)}")

    transformer = Transformer.from_crs(SOURCE_CRS[state], DST_CRS, always_xy=True)
    records = []
    election_rows = []
    repair_ledger = []
    aggregate_inputs = []
    region_groups = defaultdict(lambda: {"geometries": [], "dem": 0, "rep": 0})
    source_bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]
    output_bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]
    selected_years = Counter()
    hygiene = Counter()

    election_votes = []
    for unit_id in (row[0] for row in spine):
        for (office, year), parties in raw_elections[unit_id].items():
            for party, votes in parties.items():
                election_votes.append(ElectionVote(unit_id, office, year, party, votes))
    selected_presidents = select_latest_usable_president(election_votes)

    for rowid, (unit_id, fips, county, precinct_name, raw_geometry) in enumerate(spine, 1):
        parsed = parse_geometry(raw_geometry)
        bounds = parsed.bounds
        source_bounds = [
            min(source_bounds[0], bounds[0]), min(source_bounds[1], bounds[1]),
            max(source_bounds[2], bounds[2]), max(source_bounds[3], bounds[3]),
        ]
        geometry = prepare_geometry(
            state, unit_id, raw_geometry, transformer, repair_ledger
        )
        min_lon, min_lat, max_lon, max_lat = geometry.bounds
        output_bounds = [
            min(output_bounds[0], min_lon), min(output_bounds[1], min_lat),
            max(output_bounds[2], max_lon), max(output_bounds[3], max_lat),
        ]

        demographics = {
            variable: preferred_demo(raw_demographics[unit_id], variable)
            for variable in ALL_VARS
        }
        population = demographics["pop_total"]
        if population is None or population <= 0:
            raise RuntimeError(f"{state} {unit_id}: positive-population selection drifted")

        usable = {}
        for (office, year), parties in sorted(raw_elections[unit_id].items()):
            share = two_party(parties)
            if share is None:
                continue
            usable[(office, year)] = {
                "dem": parties["dem"],
                "rep": parties["rep"],
                "other": parties.get("other"),
                "share": share,
            }

        presidential_years = sorted(
            (year for office, year in usable if office == "president"), reverse=True
        )
        shared_selected = selected_presidents.get(unit_id)
        lean_year = shared_selected.year if shared_selected else None
        if lean_year != (presidential_years[0] if presidential_years else None):
            raise RuntimeError(f"{state} {unit_id}: shared election selection disagrees")
        previous_year = presidential_years[1] if len(presidential_years) > 1 else None
        selected = usable.get(("president", lean_year)) if lean_year else None
        previous = usable.get(("president", previous_year)) if previous_year else None
        selected_years[lean_year] += 1

        if unit_id in EXPECTED_NULL_UNITS[state]:
            if lean_year is not None:
                raise RuntimeError(f"{state} {unit_id}: expected election-null unit has lean")
            usable = {}
        elif lean_year is None:
            raise RuntimeError(f"{state} {unit_id}: unexpected election-null unit")

        for (office, year), election in sorted(usable.items()):
            election_rows.append((
                unit_id, office, year, election["dem"], election["rep"],
                election["other"], election["share"],
            ))

        lean_share = selected["share"] if selected else None
        previous_share = previous["share"] if previous else None
        lean_votes = None
        if selected:
            lean_votes = selected["dem"] + selected["rep"]
            if selected["other"] is not None:
                lean_votes += selected["other"]
        lean_shift = (
            lean_share - previous_share
            if lean_share is not None and previous_share is not None else None
        )
        source_cvap = demographics.get("cvap")
        vap_total = demographics.get("vap_total")
        cvap = source_cvap
        if cvap is not None and vap_total is not None and cvap > vap_total:
            cvap = vap_total
            hygiene["cvap_clamped_to_vap"] += 1
        turnout = lean_votes / cvap if lean_votes is not None and cvap and cvap >= 50 else None
        if turnout is not None and turnout > 1.15:
            turnout = None
            hygiene["turnout_over_1_15_to_null"] += 1
        elif lean_votes is not None and (cvap is None or cvap < 50):
            hygiene["turnout_missing_or_cvap_under_50_to_null"] += 1

        race_percentages = {
            variable: fraction(demographics.get(variable), population)
            for variable in RACE_VARS
        }
        available_race = [
            variable for variable in RACE_VARS
            if demographics.get(variable) is not None
        ]
        plurality = (
            RACE_LABELS[max(available_race, key=lambda v: demographics[v])]
            if available_race else None
        )
        education = [demographics.get(variable) for variable in EDU_VARS]
        education_total = sum(education) if all(value is not None for value in education) else None
        ba_total = (
            demographics["edu_bachelors"] + demographics["edu_graduate"]
            if education_total
            and demographics.get("edu_bachelors") is not None
            and demographics.get("edu_graduate") is not None
            else None
        )
        owner = demographics.get("housing_owner")
        renter = demographics.get("housing_renter")
        households = owner + renter if owner is not None and renter is not None else None
        income = demographics.get("income_median")
        if income is not None and income <= 0:
            income = None
            hygiene["income_nonpositive_to_null"] += 1
        if not education_total:
            hygiene["zero_education_denominator_to_null"] += 1
        if not households:
            hygiene["zero_housing_denominator_to_null"] += 1

        record = {
            "rowid": rowid,
            "unit_id": unit_id,
            "fips": fips,
            "state": state,
            "borough": county,
            "precinct_name": precinct_name,
            "min_lon": min_lon,
            "min_lat": min_lat,
            "max_lon": max_lon,
            "max_lat": max_lat,
            "geometry_wkb": wkb.dumps(geometry, hex=False, byte_order=1),
            "lean_dem_share": lean_share,
            "prev_dem_share": previous_share,
            "lean_year": lean_year,
            "prev_year": previous_year,
            "lean_label": lean_label(lean_share),
            "lean_shift": lean_shift,
            "lean_votes": lean_votes,
            "turnout_est": turnout,
            "pop_total": int(population),
            "vap_total": int(vap_total) if vap_total is not None else None,
            "cvap": int(cvap) if cvap is not None else None,
            "pct_white": race_percentages["pop_white"],
            "pct_black": race_percentages["pop_black"],
            "pct_hispanic": race_percentages["pop_hispanic"],
            "pct_asian": race_percentages["pop_asian"],
            "pct_native": race_percentages["pop_native"],
            "pct_pacific": race_percentages["pop_pacific"],
            "pct_other": race_percentages["pop_other"],
            "plurality_group": plurality,
            "pct_no_hs": fraction(demographics.get("edu_no_hs"), education_total),
            "pct_hs": fraction(demographics.get("edu_hs"), education_total),
            "pct_bachelors": fraction(demographics.get("edu_bachelors"), education_total),
            "pct_graduate": fraction(demographics.get("edu_graduate"), education_total),
            "pct_ba_or_higher": fraction(ba_total, education_total),
            "income_median": int(round(income)) if income is not None else None,
            "pop_density": demographics.get("pop_density"),
            "avg_age": demographics.get("avg_age"),
            "pct_renter": fraction(renter, households),
            "pct_owner": fraction(owner, households),
            "data_complete": 1 if selected is not None else 0,
        }
        records.append(record)
        percent_fields = [
            record[name] for name in (
                "pct_white", "pct_black", "pct_hispanic", "pct_asian",
                "pct_native", "pct_pacific", "pct_other", "pct_no_hs",
                "pct_hs", "pct_bachelors", "pct_graduate",
                "pct_ba_or_higher", "pct_renter", "pct_owner",
            ) if record[name] is not None
        ]
        if any(value < 0 or value > 1 for value in percent_fields):
            raise RuntimeError(f"{state} {unit_id}: derived percentage outside 0...1")
        aggregate_inputs.append(PrecinctAggregateInput(
            unit_id=unit_id,
            state=state,
            county=county,
            pop_total=int(population),
            demographic_complete=all(
                demographics.get(variable) is not None for variable in ALL_VARS
            ),
            lean_year=lean_year,
            dem=selected["dem"] if selected else None,
            rep=selected["rep"] if selected else None,
            lean_label=record["lean_label"],
            education_total=education_total,
            household_total=households,
            pct_white=record["pct_white"],
            pct_black=record["pct_black"],
            pct_hispanic=record["pct_hispanic"],
            pct_asian=record["pct_asian"],
            pct_native=record["pct_native"],
            pct_pacific=record["pct_pacific"],
            pct_other=record["pct_other"],
            pct_ba_or_higher=record["pct_ba_or_higher"],
            income_median=record["income_median"],
            pct_renter=record["pct_renter"],
            avg_age=record["avg_age"],
        ))
        region_key = (county, record["lean_label"] or "No data")
        region_groups[region_key]["geometries"].append(geometry)
        if selected is not None:
            region_groups[region_key]["dem"] += selected["dem"]
            region_groups[region_key]["rep"] += selected["rep"]

    validate_crs(state, source_bounds, output_bounds)
    computed_baselines = compute_scope_baselines(aggregate_inputs, meaningful_count=1)
    demographic_missing_by_variable = {
        variable: sum(
            preferred_demo(raw_demographics[unit_id], variable) is None
            for unit_id, *_ in spine
        )
        for variable in sorted(ALL_VARS)
    }
    if dict(selected_years) != expected["years"]:
        raise RuntimeError(
            f"{state}: selected year contract mismatch {dict(selected_years)}"
        )
    if {entry["unit_id"] for entry in repair_ledger} != (
        set() if state == "CO" else {entry[0] for entry in spine if not parse_geometry(entry[4]).is_valid}
    ):
        raise RuntimeError(f"{state}: geometry repair ledger is incomplete")

    regions = []
    for rowid, ((county, label), group) in enumerate(sorted(region_groups.items()), 1):
        geometry = clean_region(group["geometries"])
        total = group["dem"] + group["rep"]
        dem_share = group["dem"] / total if total else None
        if label == "No data" and dem_share is not None:
            raise RuntimeError(f"{state} {county}: no-data region has political share")
        min_lon, min_lat, max_lon, max_lat = geometry.bounds
        regions.append((
            rowid, state, county, label, dem_share,
            min_lon, min_lat, max_lon, max_lat,
            wkb.dumps(geometry, hex=False, byte_order=1),
        ))

    temporary = db_path.with_suffix(".sqlite.tmp")
    ledger_temporary = ledger_path.with_suffix(".json.tmp")
    manifest_temporary = manifest_path.with_suffix(".json.tmp")
    for path in (*targets, temporary, ledger_temporary, manifest_temporary):
        require_regular_or_missing(path)
    if temporary.exists():
        temporary.unlink()
    connection = sqlite3.connect(temporary)
    try:
        connection.execute("PRAGMA page_size=4096")
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.executescript(SCHEMA)
        connection.executemany(
            f"INSERT INTO precincts ({','.join(PRECINCT_COLUMNS)}) "
            f"VALUES ({','.join(':' + column for column in PRECINCT_COLUMNS)})",
            records,
        )
        connection.executemany(
            "INSERT INTO precinct_elections VALUES (?,?,?,?,?,?,?)", election_rows
        )
        baseline_columns = (
            "scope", "precinct_count", "political_precinct_count", "pop_total",
            "pct_white", "pct_black",
            "pct_hispanic", "pct_asian", "pct_native", "pct_pacific", "pct_other",
            "pct_ba_or_higher", "income_median", "pct_renter", "avg_age",
            "pres24_dem_share",
        )
        connection.executemany(
            f"INSERT INTO baselines ({','.join(baseline_columns)}) "
            f"VALUES ({','.join(':' + column for column in baseline_columns)})",
            [vars(baseline) for baseline in computed_baselines],
        )
        connection.executemany(
            "INSERT INTO precinct_rtree VALUES (?,?,?,?,?)",
            [
                (record["rowid"], record["min_lon"], record["max_lon"],
                 record["min_lat"], record["max_lat"])
                for record in records
            ],
        )
        connection.executemany(
            "INSERT INTO county_lean_regions VALUES (?,?,?,?,?,?,?,?,?,?)", regions
        )
        connection.commit()
        connection.execute("ANALYZE")
        connection.execute("VACUUM")
        connection.commit()
    finally:
        connection.close()
    verify = sqlite3.connect(f"file:{temporary}?mode=ro&immutable=1", uri=True)
    verify.execute("PRAGMA query_only=ON")
    integrity = verify.execute("PRAGMA integrity_check").fetchone()[0]
    output_count = verify.execute("SELECT COUNT(*) FROM precincts").fetchone()[0]
    rtree_count = verify.execute("SELECT COUNT(*) FROM precinct_rtree").fetchone()[0]
    baseline_count = verify.execute("SELECT COUNT(*) FROM baselines").fetchone()[0]
    county_count = verify.execute(
        "SELECT COUNT(DISTINCT borough) FROM precincts"
    ).fetchone()[0]
    null_units = {
        row[0] for row in verify.execute(
            "SELECT unit_id FROM precincts WHERE lean_year IS NULL"
        )
    }
    null_field_violations = verify.execute(
        """
        SELECT COUNT(*) FROM precincts
        WHERE lean_year IS NULL AND (
          lean_dem_share IS NOT NULL OR prev_dem_share IS NOT NULL OR
          prev_year IS NOT NULL OR lean_label IS NOT NULL OR
          lean_shift IS NOT NULL OR lean_votes IS NOT NULL OR turnout_est IS NOT NULL
        )
        """
    ).fetchone()[0]
    null_election_rows = verify.execute(
        """
        SELECT COUNT(*) FROM precinct_elections
        WHERE unit_id IN (SELECT unit_id FROM precincts WHERE lean_year IS NULL)
        """
    ).fetchone()[0]
    no_data_region_count = verify.execute(
        "SELECT COUNT(*) FROM county_lean_regions WHERE lean_label='No data' AND dem_share IS NULL"
    ).fetchone()[0]
    bad_no_data_regions = verify.execute(
        "SELECT COUNT(*) FROM county_lean_regions WHERE lean_label='No data' AND dem_share IS NOT NULL"
    ).fetchone()[0]
    verify.close()

    checks = {
        "integrity_check": integrity,
        "precinct_count": output_count,
        "rtree_count": rtree_count,
        "county_count": county_count,
        "baseline_count": baseline_count,
        "null_units": sorted(null_units),
        "null_political_field_violations": null_field_violations,
        "null_unit_election_rows": null_election_rows,
        "no_data_region_count": no_data_region_count,
        "bad_no_data_regions": bad_no_data_regions,
    }
    if not (
        integrity == "ok"
        and output_count == expected["total"]
        and rtree_count == expected["total"]
        and baseline_count == county_count + 1
        and null_units == EXPECTED_NULL_UNITS[state]
        and null_field_violations == 0
        and null_election_rows == 0
        and no_data_region_count > 0
        and bad_no_data_regions == 0
    ):
        raise RuntimeError(f"{state}: output verification failed: {checks}")

    ledger_document = {
        "schema_version": 1,
        "state": state,
        "repair_method": "shapely.make_valid linework, polygonal components only",
        "source_crs": SOURCE_CRS[state],
        "repair_count": len(repair_ledger),
        "repairs": sorted(repair_ledger, key=lambda entry: entry["unit_id"]),
    }
    ledger_temporary.write_text(
        json.dumps(ledger_document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    year_distribution = {
        "null" if year is None else str(year): count
        for year, count in sorted(
            selected_years.items(), key=lambda item: (-1 if item[0] is None else item[0]),
            reverse=True,
        )
    }
    manifest = {
        "schema_version": 1,
        "artifact_kind": "phase2b_private_fallback_nonshipping_state_candidate",
        "state": state,
        "state_name": STATE_NAMES[state],
        "release_gate": {
            "status": "BLOCKED",
            "shipping_authorized": False,
            "reason": (
                "The official 2024 polygon/crosswalk lineage and affirmative election-file "
                "transformation, redistribution, attribution, and offline App Store bundling "
                "rights remain unverified. This candidate is not authorized to merge or ship "
                "in Phase 2B. The strict 2024 lineage gate remains blocked."
            ),
        },
        "source": {
            "path": str(SOURCE.relative_to(ROOT)),
            "sha256": source_sha,
            "open_mode": "SQLite URI mode=ro, immutable=1, PRAGMA query_only=ON",
            "election_omission_zero_certifications": [],
        },
        "crs": {
            "source": SOURCE_CRS[state],
            "destination": DST_CRS,
            "source_bounds": source_bounds,
            "output_bounds": output_bounds,
            "proof": (
                "Source coordinates have Web Mercator magnitude. An explicit EPSG:3857 to "
                "EPSG:4326 transform places the complete state layer inside the asserted "
                "state envelope. The generic private-source adapter in the repository also "
                "uses EPSG:3857 for states without a state-specific override."
            ),
            "repository_evidence": [
                {
                    "path": "pipeline/build_region_precincts.py",
                    "fact": (
                        "The private-source adapter declares EPSG:3857 as its source CRS and "
                        "uses it for states without a state-specific override. OR and CO have "
                        "no different override."
                    ),
                },
                {
                    "path": "precincts_2026_primary.db",
                    "fact": (
                        "The complete source coordinate bounds have projected-meter magnitude, "
                        "and the explicit transform yields the recorded state-conforming bounds."
                    ),
                },
            ],
        },
        "selection_contract": {
            "positive_population_only": True,
            "unit_count": len(records),
            "selected_presidential_year_distribution": year_distribution,
            "requires_dem_and_rep_rows": True,
            "requires_positive_two_party_total": True,
            "null_units": sorted(EXPECTED_NULL_UNITS[state]),
            "null_units_keep_geometry_and_demographics": True,
            "null_units_excluded_from_political_rows_and_aggregates": True,
            "older_history_requires_usable_dem_and_rep_rows": True,
            "lean_votes_rule": (
                "Democratic plus Republican votes when other is absent and unknown. Democratic "
                "plus Republican plus other only when an other row is present. An absent other "
                "row remains NULL in precinct_elections and is never certified as zero."
            ),
        },
        "derived_field_hygiene": {
            "cvap_clamped_to_vap": hygiene["cvap_clamped_to_vap"],
            "income_nonpositive_to_null": hygiene["income_nonpositive_to_null"],
            "zero_education_denominator_to_null": hygiene[
                "zero_education_denominator_to_null"
            ],
            "zero_housing_denominator_to_null": hygiene[
                "zero_housing_denominator_to_null"
            ],
            "turnout_missing_or_cvap_under_50_to_null": hygiene[
                "turnout_missing_or_cvap_under_50_to_null"
            ],
            "turnout_over_1_15_to_null": hygiene["turnout_over_1_15_to_null"],
            **dict(sorted(hygiene.items())),
            "cvap_rule": "min(source cvap, vap_total) when both exist",
            "percent_range_asserted": "all non-null derived percentages are within 0...1",
            "turnout_rule": "NULL when cvap is missing, cvap is under 50, or result exceeds 1.15",
            "retained_units_with_all_required_source_demographics": sum(
                1 for item in aggregate_inputs if item.demographic_complete
            ),
            "retained_units_with_missing_required_source_demographics": sum(
                1 for item in aggregate_inputs if not item.demographic_complete
            ),
            "missing_source_values_by_required_variable": demographic_missing_by_variable,
            "derived_null_policy": (
                "Ratio fields are NULL only when their own source numerator is missing or their "
                "denominator is missing, zero, or product-invalid. Nonpositive income is NULL."
            ),
        },
        "geometry": {
            "invalid_source_count": len(repair_ledger),
            "repair_ledger": ledger_path.name,
            "repair_ledger_sha256": sha256(ledger_temporary),
            "simplify_tolerance_degrees": SIMPLIFY_TOLERANCE,
        },
        "database": {
            "path": db_path.name,
            "sha256": sha256(temporary),
            "size_bytes": temporary.stat().st_size,
            "tables": [
                "precincts", "precinct_elections", "baselines",
                "precinct_rtree", "county_lean_regions",
            ],
        },
        "verification": checks,
    }
    manifest_temporary.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    install_artifact_set(
        [
            (ledger_temporary, ledger_path),
            (temporary, db_path),
            (manifest_temporary, manifest_path),
        ],
        output_dir,
    )
    return manifest


def safe_output_dir(raw_path: str) -> Path:
    output_dir = Path(os.path.abspath(Path(raw_path).expanduser()))
    expected = Path(os.path.abspath(SAFE_OUTPUT_DIR))
    if output_dir != expected:
        raise argparse.ArgumentTypeError(
            f"unsafe output directory. Only {SAFE_OUTPUT_DIR} is permitted"
        )
    if output_dir.is_symlink() or output_dir.parent.is_symlink():
        raise argparse.ArgumentTypeError("candidate output directory cannot be a symlink")
    return output_dir


def safe_source(raw_path: str) -> Path:
    source = Path(os.path.abspath(Path(raw_path).expanduser()))
    expected = Path(os.path.abspath(SOURCE))
    if source != expected or source.is_symlink():
        raise argparse.ArgumentTypeError(
            f"unsafe source. Only the read-only artifact {SOURCE} is permitted"
        )
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", default=str(SOURCE), type=safe_source)
    parser.add_argument(
        "--output-dir", default=str(SAFE_OUTPUT_DIR), type=safe_output_dir
    )
    parser.add_argument(
        "--states", default="OR,CO",
        help="Comma-separated subset of OR,CO. Default: OR,CO",
    )
    parser.add_argument(
        "--replace", action="store_true",
        help="Replace existing candidate outputs inside the guarded output directory",
    )
    args = parser.parse_args()

    states = tuple(state.strip().upper() for state in args.states.split(",") if state.strip())
    if not states or len(states) != len(set(states)) or any(state not in STATES for state in states):
        parser.error("--states must be a unique comma-separated subset of OR,CO")
    if Path.cwd().resolve() != ROOT:
        parser.error(f"run this script from the repository root: {ROOT}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.output_dir.is_symlink() or args.output_dir.parent.is_symlink():
        parser.error("candidate output directory cannot be a symlink")
    source_hash = sha256(args.src)
    source = sqlite3.connect(f"file:{args.src}?mode=ro&immutable=1", uri=True)
    source.execute("PRAGMA query_only=ON")
    try:
        for state in states:
            manifest = build_state(
                source, source_hash, state, args.output_dir, args.replace
            )
            distribution = manifest["selection_contract"][
                "selected_presidential_year_distribution"
            ]
            print(
                f"{state}: {manifest['selection_contract']['unit_count']} precincts, "
                f"years={distribution}, repairs={manifest['geometry']['invalid_source_count']}, "
                f"sha256={manifest['database']['sha256']}"
            )
    finally:
        source.close()


if __name__ == "__main__":
    main()
