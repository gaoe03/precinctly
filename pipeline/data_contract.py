#!/usr/bin/env python3
"""Shared data contracts for bundled precinct rows and political baselines."""

from __future__ import annotations

from dataclasses import dataclass
import sqlite3
from typing import Iterable, Sequence


METRO_COUNTIES = {
    "metro|NY|New York City": ("Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island"),
}
REGION_FIPS = {
    "region|DMV": (
        "11001", "24031", "24033", "51013", "51510", "51059", "51600",
        "51610", "51107", "51153", "51683", "51685",
    ),
}


class DataContractError(ValueError):
    """Raised when stored data cannot support an unambiguous aggregate."""


@dataclass(frozen=True)
class PoliticalAggregate:
    dem: int
    rep: int
    precinct_count: int

    @property
    def dem_share(self) -> float | None:
        total = self.dem + self.rep
        return self.dem / total if total else None


def cap_cvap_to_vap(cvap: float | int | None, vap_total: float | int | None):
    """Cap a known CVAP at a known VAP while preserving unknown values."""
    if cvap is not None and vap_total is not None and cvap > vap_total:
        return vap_total
    return cvap


def turnout_from_cvap(lean_votes: float | int | None, cvap: float | int | None) -> float | None:
    """Apply the bundled database turnout contract to a CVAP denominator."""
    turnout = lean_votes / cvap if lean_votes is not None and cvap and cvap >= 50 else None
    return None if turnout is not None and turnout > 1.15 else turnout


def aggregate_two_party_votes(rows: Iterable[Sequence[object]]) -> PoliticalAggregate:
    """Sum eligible Democratic and Republican vote pairs without inventing unknown votes."""
    dem_total = rep_total = precinct_count = 0
    for raw_dem, raw_rep in rows:
        if raw_dem is None or raw_rep is None:
            continue
        dem, rep = int(raw_dem), int(raw_rep)
        if dem < 0 or rep < 0:
            raise DataContractError(f"negative selected-year votes: dem={dem}, rep={rep}")
        if dem + rep <= 0:
            continue
        dem_total += dem
        rep_total += rep
        precinct_count += 1
    return PoliticalAggregate(dem_total, rep_total, precinct_count)


def selected_president_aggregate(
    connection: sqlite3.Connection,
    precinct_where: str,
    parameters: Sequence[object] = (),
) -> PoliticalAggregate:
    """Aggregate each precinct's selected presidential year within a trusted scope clause."""
    duplicates = connection.execute(
        f"""
        SELECT p.unit_id, COUNT(e.rowid)
        FROM precincts p
        LEFT JOIN precinct_elections e
          ON e.unit_id = p.unit_id
         AND e.office = 'president'
         AND e.year = p.lean_year
        WHERE p.lean_year IS NOT NULL AND ({precinct_where})
        GROUP BY p.unit_id
        HAVING COUNT(e.rowid) != 1
        LIMIT 1
        """,
        parameters,
    ).fetchone()
    if duplicates:
        raise DataContractError(
            f"{duplicates[0]} has {duplicates[1]} presidential rows for its selected lean_year"
        )
    rows = connection.execute(
        f"""
        SELECT e.dem, e.rep
        FROM precincts p
        JOIN precinct_elections e
          ON e.unit_id = p.unit_id
         AND e.office = 'president'
         AND e.year = p.lean_year
        WHERE {precinct_where}
        """,
        parameters,
    )
    return aggregate_two_party_votes(rows)


def baseline_scope_filter(scope: str) -> tuple[str, tuple[object, ...]]:
    """Return the precinct predicate for one persisted app baseline scope."""
    if scope in METRO_COUNTIES:
        state = scope.split("|", 2)[1]
        counties = METRO_COUNTIES[scope]
        return (
            f"p.state = ? AND p.borough IN ({','.join('?' for _ in counties)})",
            (state, *counties),
        )
    if scope in REGION_FIPS:
        fips = REGION_FIPS[scope]
        return f"p.fips IN ({','.join('?' for _ in fips)})", fips
    parts = scope.split("|")
    if len(parts) == 1 and scope:
        return "p.state = ?", (scope,)
    if len(parts) == 3 and parts[0] == "county" and all(parts[1:]):
        return "p.state = ? AND p.borough = ?", (parts[1], parts[2])
    raise DataContractError(f"unsupported baseline scope {scope!r}")
