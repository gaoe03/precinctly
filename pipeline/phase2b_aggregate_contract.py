#!/usr/bin/env python3
"""Reusable Phase 2B aggregation contracts for candidate database builders.

This module is deliberately separate from the shipping build.  It does not open or mutate a
database on import.  A candidate builder can use it to:

* select each unit's latest usable general presidential result without guessing missing votes;
* compute state and meaningful-county baselines with separate demographic and political pools;
* retain the app's geographic ``precinct_count`` while adding a political-data count when the
  candidate baseline schema is writable;
* form county lean-region buckets whose no-data share is SQL NULL, never a fabricated 50 percent;
* run state-scoped rankings that exclude NULL values.

The app-facing baseline column remains named ``pres24_dem_share`` for schema compatibility.  For
Phase 2B candidates its value is the aggregate of every precinct's selected ``lean_year``, so a
state or county may legitimately combine election years.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
import sqlite3
from typing import Iterable, Sequence


DEMOGRAPHIC_FIELDS = (
    "pct_white",
    "pct_black",
    "pct_hispanic",
    "pct_asian",
    "pct_native",
    "pct_pacific",
    "pct_other",
    "pct_ba_or_higher",
    "income_median",
    "pct_renter",
    "avg_age",
)

APP_BASELINE_FIELDS = (
    "scope",
    "precinct_count",
    "pop_total",
    *DEMOGRAPHIC_FIELDS,
    "pres24_dem_share",
)

PARTY_ALIASES = {
    "dem": "dem",
    "democrat": "dem",
    "democratic": "dem",
    "rep": "rep",
    "republican": "rep",
    "other": "other",
}

NO_DATA_LABEL = "No data"
DEFAULT_MEANINGFUL_COUNT = 25


class Phase2BContractError(ValueError):
    """Raised when candidate input would make an unknown value look known."""


@dataclass(frozen=True)
class ElectionVote:
    unit_id: str
    office: str
    year: int
    party: str
    votes: int | None
    election_type: str = "general"


@dataclass(frozen=True)
class CertifiedZero:
    """Explicit source evidence that an otherwise absent party total is certified as zero."""

    unit_id: str
    office: str
    year: int
    party: str


@dataclass(frozen=True)
class SelectedPresident:
    unit_id: str
    year: int
    dem: int
    rep: int
    other: int | None

    @property
    def two_party_votes(self) -> int:
        return self.dem + self.rep

    @property
    def dem_share(self) -> float:
        return self.dem / self.two_party_votes


@dataclass(frozen=True)
class PrecinctAggregateInput:
    unit_id: str
    state: str
    county: str
    pop_total: int | None
    demographic_complete: bool
    lean_year: int | None = None
    dem: int | None = None
    rep: int | None = None
    lean_label: str | None = None
    education_total: float | None = None
    household_total: float | None = None
    pct_white: float | None = None
    pct_black: float | None = None
    pct_hispanic: float | None = None
    pct_asian: float | None = None
    pct_native: float | None = None
    pct_pacific: float | None = None
    pct_other: float | None = None
    pct_ba_or_higher: float | None = None
    income_median: float | None = None
    pct_renter: float | None = None
    avg_age: float | None = None

    @property
    def has_usable_politics(self) -> bool:
        return (
            self.lean_year is not None
            and self.dem is not None
            and self.rep is not None
            and self.dem >= 0
            and self.rep >= 0
            and self.dem + self.rep > 0
        )


@dataclass(frozen=True)
class ScopeBaseline:
    scope: str
    precinct_count: int
    political_precinct_count: int
    pop_total: int | None
    pct_white: float | None
    pct_black: float | None
    pct_hispanic: float | None
    pct_asian: float | None
    pct_native: float | None
    pct_pacific: float | None
    pct_other: float | None
    pct_ba_or_higher: float | None
    income_median: int | None
    pct_renter: float | None
    avg_age: float | None
    pres24_dem_share: float | None

    def app_row(self) -> dict[str, object]:
        return {field: getattr(self, field) for field in APP_BASELINE_FIELDS}


@dataclass(frozen=True)
class LeanRegionBucket:
    state: str
    county: str
    lean_label: str
    dem_share: float | None
    geographic_precinct_count: int
    political_precinct_count: int
    unit_ids: tuple[str, ...]


def _party(value: str) -> str | None:
    return PARTY_ALIASES.get(value.strip().lower())


def _validate_votes(votes: int | None, context: str) -> None:
    if votes is not None and votes < 0:
        raise Phase2BContractError(f"negative votes for {context}: {votes}")


def select_latest_usable_president(
    rows: Iterable[ElectionVote],
    certified_zero_evidence: Iterable[CertifiedZero] = (),
) -> dict[str, SelectedPresident]:
    """Select the latest usable general presidential year for each unit.

    A year is usable only when Democratic and Republican totals are both known and their sum is
    positive.  A literal zero result row is known.  A missing row is unknown unless a separate
    ``CertifiedZero`` record explicitly covers that unit, office, year, and party.
    """

    evidence: set[tuple[str, str, int, str]] = set()
    for item in certified_zero_evidence:
        party = _party(item.party)
        if party not in {"dem", "rep", "other"}:
            raise Phase2BContractError(f"certified-zero evidence has unsupported party {item.party!r}")
        evidence.add((item.unit_id, item.office.strip().lower(), item.year, party))

    totals: dict[tuple[str, int], dict[str, int]] = defaultdict(lambda: defaultdict(int))
    present: dict[tuple[str, int], set[str]] = defaultdict(set)
    units: set[str] = set()
    for row in rows:
        if row.office.strip().lower() != "president" or row.election_type.strip().lower() != "general":
            continue
        party = _party(row.party)
        if party is None:
            continue
        _validate_votes(row.votes, f"{row.unit_id} {row.year} {party}")
        units.add(row.unit_id)
        if row.votes is None:
            continue
        key = (row.unit_id, row.year)
        totals[key][party] += row.votes
        present[key].add(party)

    for unit_id, office, year, party in evidence:
        if office != "president":
            continue
        units.add(unit_id)
        key = (unit_id, year)
        if party not in present[key]:
            totals[key][party] = 0
            present[key].add(party)

    selected: dict[str, SelectedPresident] = {}
    for unit_id in sorted(units):
        years = sorted((year for uid, year in present if uid == unit_id), reverse=True)
        for year in years:
            key = (unit_id, year)
            if not {"dem", "rep"}.issubset(present[key]):
                continue
            dem = totals[key]["dem"]
            rep = totals[key]["rep"]
            if dem + rep <= 0:
                continue
            selected[unit_id] = SelectedPresident(
                unit_id=unit_id,
                year=year,
                dem=dem,
                rep=rep,
                other=totals[key].get("other") if "other" in present[key] else None,
            )
            break
    return selected


def _validate_aggregate_input(record: PrecinctAggregateInput) -> None:
    if not record.unit_id or not record.state:
        raise Phase2BContractError("aggregate inputs require unit_id and state")
    for name in ("dem", "rep", "pop_total", "education_total", "household_total"):
        value = getattr(record, name)
        if value is not None and value < 0:
            raise Phase2BContractError(f"{record.unit_id} has negative {name}: {value}")
    if record.lean_year is not None and not record.has_usable_politics:
        raise Phase2BContractError(
            f"{record.unit_id} has lean_year {record.lean_year} without usable Democratic and Republican votes"
        )
    if record.has_usable_politics and not record.lean_label:
        raise Phase2BContractError(f"{record.unit_id} has usable political data without lean_label")


def compute_scope_baselines(
    records: Iterable[PrecinctAggregateInput],
    meaningful_count: int = DEFAULT_MEANINGFUL_COUNT,
) -> list[ScopeBaseline]:
    """Build state baselines and county baselines meeting the geographic count floor."""

    if meaningful_count < 1:
        raise Phase2BContractError("meaningful_count must be positive")
    materialized = list(records)
    for record in materialized:
        _validate_aggregate_input(record)

    scopes: dict[str, list[PrecinctAggregateInput]] = defaultdict(list)
    counties: dict[str, list[PrecinctAggregateInput]] = defaultdict(list)
    for record in materialized:
        scopes[record.state].append(record)
        if record.county:
            counties[f"county|{record.state}|{record.county}"].append(record)
    scopes.update({scope: rows for scope, rows in counties.items() if len(rows) >= meaningful_count})

    output: list[ScopeBaseline] = []
    for scope in sorted(scopes):
        rows = scopes[scope]
        # Every retained positive-population unit belongs in geographic scope totals.  Individual
        # derived fields can still be absent when their own source denominator is zero, so each
        # metric gets its own non-null population denominator instead of dropping the whole unit.
        demographic_rows = [row for row in rows if row.pop_total is not None and row.pop_total > 0]
        pop_total = sum(row.pop_total or 0 for row in demographic_rows)
        demographic_values: dict[str, float | None] = {}
        for name in DEMOGRAPHIC_FIELDS:
            if name == "pct_ba_or_higher":
                weight_name = "education_total"
            elif name in {"income_median", "pct_renter"}:
                weight_name = "household_total"
            else:
                weight_name = "pop_total"
            valid_rows = [
                row
                for row in demographic_rows
                if getattr(row, name) is not None
                and (name != "income_median" or float(getattr(row, name)) > 0)
                and getattr(row, weight_name) is not None
                and float(getattr(row, weight_name)) > 0
            ]
            denominator = sum(float(getattr(row, weight_name)) for row in valid_rows)
            numerator = sum(
                float(getattr(row, name)) * float(getattr(row, weight_name))
                for row in valid_rows
            )
            demographic_values[name] = numerator / denominator if denominator else None

        political_rows = [row for row in rows if row.has_usable_politics]
        dem_total = sum(row.dem or 0 for row in political_rows)
        rep_total = sum(row.rep or 0 for row in political_rows)
        political_denominator = dem_total + rep_total
        share = dem_total / political_denominator if political_denominator else None

        income = demographic_values.pop("income_median")
        output.append(
            ScopeBaseline(
                scope=scope,
                precinct_count=len(rows),
                political_precinct_count=len(political_rows),
                pop_total=pop_total or None,
                income_median=round(income) if income is not None else None,
                pres24_dem_share=share,
                **demographic_values,
            )
        )
    return output


def county_lean_region_buckets(
    records: Iterable[PrecinctAggregateInput],
) -> list[LeanRegionBucket]:
    """Group county geography for dissolution while keeping no-data color semantics explicit."""

    grouped: dict[tuple[str, str, str], list[PrecinctAggregateInput]] = defaultdict(list)
    for record in records:
        _validate_aggregate_input(record)
        label = record.lean_label if record.has_usable_politics else NO_DATA_LABEL
        grouped[(record.state, record.county, label or NO_DATA_LABEL)].append(record)

    output = []
    for (state, county, label), rows in sorted(grouped.items()):
        political_rows = [row for row in rows if row.has_usable_politics]
        dem = sum(row.dem or 0 for row in political_rows)
        rep = sum(row.rep or 0 for row in political_rows)
        denominator = dem + rep
        # This explicit branch is the no-fake-Even contract.  Python None binds as SQL NULL.
        share = None if label == NO_DATA_LABEL else (dem / denominator if denominator else None)
        output.append(
            LeanRegionBucket(
                state=state,
                county=county,
                lean_label=label,
                dem_share=share,
                geographic_precinct_count=len(rows),
                political_precinct_count=len(political_rows),
                unit_ids=tuple(sorted(row.unit_id for row in rows)),
            )
        )
    return output


def ensure_baselines_table(connection: sqlite3.Connection) -> bool:
    """Create/extend the candidate baseline schema without changing the app-read columns.

    Returns whether ``political_precinct_count`` is available.  On a legacy writable table it is
    added as a new ignored-by-the-app column.  If SQLite rejects that additive migration, callers
    can still write the app contract and retain the political count in their audit report.
    """

    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS baselines (
          scope TEXT PRIMARY KEY, precinct_count INT, political_precinct_count INT, pop_total INT,
          pct_white REAL, pct_black REAL, pct_hispanic REAL, pct_asian REAL,
          pct_native REAL, pct_pacific REAL, pct_other REAL,
          pct_ba_or_higher REAL, income_median INT, pct_renter REAL, avg_age REAL,
          pres24_dem_share REAL
        )
        """
    )
    columns = {row[1] for row in connection.execute("PRAGMA table_info(baselines)")}
    missing = set(APP_BASELINE_FIELDS) - columns
    if missing:
        raise Phase2BContractError(f"baselines table lacks app contract columns: {', '.join(sorted(missing))}")
    if "political_precinct_count" not in columns:
        try:
            connection.execute("ALTER TABLE baselines ADD COLUMN political_precinct_count INT")
        except sqlite3.OperationalError:
            return False
    return True


def write_scope_baselines(
    connection: sqlite3.Connection,
    baselines: Sequence[ScopeBaseline],
) -> bool:
    """Upsert computed candidate baselines and return whether the political count was persisted."""

    has_political_count = ensure_baselines_table(connection)
    columns = list(APP_BASELINE_FIELDS)
    if has_political_count:
        columns.insert(2, "political_precinct_count")
    sql = (
        f"INSERT OR REPLACE INTO baselines ({','.join(columns)}) "
        f"VALUES ({','.join('?' for _ in columns)})"
    )
    payload = [tuple(getattr(row, name) for name in columns) for row in baselines]
    connection.executemany(sql, payload)
    return has_political_count


def _table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}


def load_aggregate_inputs(
    connection: sqlite3.Connection,
    states: Sequence[str] | None = None,
) -> list[PrecinctAggregateInput]:
    """Load candidate rows, joining politics only at each precinct's selected ``lean_year``."""

    precinct_columns = _table_columns(connection, "precincts")
    required = {"unit_id", "state", "borough", "pop_total", "lean_year", "lean_label", *DEMOGRAPHIC_FIELDS}
    missing = required - precinct_columns
    if missing:
        raise Phase2BContractError(f"precincts table lacks columns: {', '.join(sorted(missing))}")

    explicit_complete = "demographic_complete" in precinct_columns
    select_columns = ["unit_id", "state", "borough", "pop_total", "lean_year", "lean_label"]
    select_columns.extend(DEMOGRAPHIC_FIELDS)
    if explicit_complete:
        select_columns.append("demographic_complete")
    sql = f"SELECT {', '.join(select_columns)} FROM precincts"
    binds: list[object] = []
    if states:
        sql += f" WHERE state IN ({','.join('?' for _ in states)})"
        binds.extend(states)
    sql += " ORDER BY state, borough, unit_id"

    results: list[PrecinctAggregateInput] = []
    for values in connection.execute(sql, binds):
        raw = dict(zip(select_columns, values))
        lean_year = raw["lean_year"]
        dem = rep = None
        if lean_year is not None:
            election_rows = connection.execute(
                """
                SELECT dem, rep FROM precinct_elections
                WHERE unit_id = ? AND office = 'president' AND year = ?
                """,
                (raw["unit_id"], lean_year),
            ).fetchall()
            if len(election_rows) != 1:
                raise Phase2BContractError(
                    f"{raw['unit_id']} lean_year {lean_year} has {len(election_rows)} matching president rows"
                )
            dem, rep = election_rows[0]

        if explicit_complete:
            demographic_complete = bool(raw["demographic_complete"])
        else:
            demographic_complete = all(raw[name] is not None for name in DEMOGRAPHIC_FIELDS)
        record = PrecinctAggregateInput(
            unit_id=raw["unit_id"],
            state=raw["state"],
            county=raw["borough"] or "",
            pop_total=raw["pop_total"],
            demographic_complete=demographic_complete,
            lean_year=lean_year,
            dem=dem,
            rep=rep,
            lean_label=raw["lean_label"],
            **{name: raw[name] for name in DEMOGRAPHIC_FIELDS},
        )
        _validate_aggregate_input(record)
        results.append(record)
    return results


RANKABLE_FIELDS = frozenset({"lean_dem_share", "pop_total", *DEMOGRAPHIC_FIELDS})


def ranked_precincts(
    connection: sqlite3.Connection,
    metric: str,
    state: str,
    *,
    descending: bool = True,
    limit: int = 100,
) -> list[sqlite3.Row | tuple]:
    """Return a state-scoped ranking whose metric can never be SQL NULL."""

    if metric not in RANKABLE_FIELDS:
        raise Phase2BContractError(f"unsupported ranking metric {metric!r}")
    if limit < 1:
        raise Phase2BContractError("ranking limit must be positive")
    direction = "DESC" if descending else "ASC"
    return connection.execute(
        f"""
        SELECT unit_id, state, borough, {metric}
        FROM precincts
        WHERE state = ? AND {metric} IS NOT NULL
        ORDER BY {metric} {direction}, unit_id ASC
        LIMIT ?
        """,
        (state, limit),
    ).fetchall()
