"""Tiny functional coverage tracker for cocotb regressions.

Tests call cover("bin.id"). Each test writes JSONL hits to the file named by
FUNCTIONAL_COVERAGE_FILE. The merge command deduplicates hits, compares them
against coverage_plan.json, and emits JSON/Markdown reports.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPORTS = ROOT / "reports"
DEFAULT_PLAN = ROOT / "coverage" / "coverage_plan.json"


def _coverage_file() -> Path:
    return Path(os.environ.get("FUNCTIONAL_COVERAGE_FILE", DEFAULT_REPORTS / "manual_coverage.jsonl"))


def cover(bin_id: str, **metadata: Any) -> None:
    """Record one functional coverage hit.

    The function intentionally stays forgiving inside simulations: invalid JSON
    or filesystem failures should surface during merge, not disturb signal-level
    debug unless the test itself asserts.
    """

    path = _coverage_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {"bin_id": bin_id, "time": time.time()}
    if metadata:
        record["metadata"] = metadata
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def _load_plan(plan_path: Path) -> list[dict[str, Any]]:
    data = json.loads(plan_path.read_text(encoding="utf-8"))
    bins = data.get("bins", [])
    if not isinstance(bins, list):
        raise ValueError("coverage_plan.json must contain a list field named 'bins'")
    seen: set[str] = set()
    for item in bins:
        bin_id = item.get("id")
        if not bin_id:
            raise ValueError(f"Coverage bin without id: {item!r}")
        if bin_id in seen:
            raise ValueError(f"Duplicate coverage bin id: {bin_id}")
        seen.add(bin_id)
    return bins


def _read_hits(reports_dir: Path) -> dict[str, list[dict[str, Any]]]:
    hits: dict[str, list[dict[str, Any]]] = {}
    for path in sorted(reports_dir.glob("*_coverage.jsonl")):
        for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid JSON in {path}:{line_no}: {exc}") from exc
            bin_id = record.get("bin_id")
            if not isinstance(bin_id, str):
                raise ValueError(f"Coverage hit without string bin_id in {path}:{line_no}")
            record["source_file"] = path.name
            hits.setdefault(bin_id, []).append(record)
    return hits


def _write_reports(plan: list[dict[str, Any]], hits: dict[str, list[dict[str, Any]]], reports_dir: Path) -> tuple[Path, Path, list[str]]:
    reports_dir.mkdir(parents=True, exist_ok=True)
    planned_ids = [item["id"] for item in plan]
    hit_ids = set(hits)
    missing = [bin_id for bin_id in planned_ids if bin_id not in hit_ids]
    unknown = sorted(hit_ids - set(planned_ids))
    covered = len(planned_ids) - len(missing)
    percent = (covered / len(planned_ids) * 100.0) if planned_ids else 100.0

    json_report = {
        "total_bins": len(planned_ids),
        "covered_bins": covered,
        "coverage_percent": round(percent, 2),
        "missing_bins": missing,
        "unknown_bins": unknown,
        "bins": [
            {
                "id": item["id"],
                "dut": item.get("dut", ""),
                "owner": item.get("owner", ""),
                "description": item.get("description", ""),
                "hit_count": len(hits.get(item["id"], [])),
                "covered": item["id"] in hit_ids,
            }
            for item in plan
        ],
    }

    json_path = reports_dir / "functional_coverage.json"
    md_path = reports_dir / "functional_coverage.md"
    json_path.write_text(json.dumps(json_report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "# Functional Coverage Report",
        "",
        f"- Total bins: {len(planned_ids)}",
        f"- Covered bins: {covered}",
        f"- Coverage: {percent:.2f}%",
        f"- Missing bins: {len(missing)}",
        f"- Unknown hits: {len(unknown)}",
        "",
        "| Status | Bin | DUT | Owner | Description | Hits |",
        "| --- | --- | --- | --- | --- | ---: |",
    ]
    for item in json_report["bins"]:
        status = "PASS" if item["covered"] else "MISS"
        lines.append(
            f"| {status} | `{item['id']}` | `{item['dut']}` | `{item['owner']}` | "
            f"{item['description']} | {item['hit_count']} |"
        )
    if unknown:
        lines += ["", "## Unknown Hits", ""]
        lines.extend(f"- `{bin_id}`" for bin_id in unknown)
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return json_path, md_path, missing


def merge(plan_path: Path = DEFAULT_PLAN, reports_dir: Path = DEFAULT_REPORTS) -> int:
    plan = _load_plan(plan_path)
    hits = _read_hits(reports_dir)
    json_path, md_path, missing = _write_reports(plan, hits, reports_dir)
    print(f"Wrote {json_path}")
    print(f"Wrote {md_path}")
    if missing:
        print("Missing coverage bins:", file=sys.stderr)
        for bin_id in missing:
            print(f"  - {bin_id}", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Functional coverage merge tool")
    sub = parser.add_subparsers(dest="command", required=True)
    merge_parser = sub.add_parser("merge")
    merge_parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
    merge_parser.add_argument("--reports", type=Path, default=DEFAULT_REPORTS)
    args = parser.parse_args(argv)
    if args.command == "merge":
        return merge(args.plan, args.reports)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
