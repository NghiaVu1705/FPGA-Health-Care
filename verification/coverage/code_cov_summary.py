"""Summarise Verilator line coverage from an LCOV merged.info file.

verilator_coverage's own "Total coverage" headline counts *uncovered* points and
is easy to misread. This computes the standard per-file and total LINE coverage
(lines hit / lines found) from the DA records and writes a Markdown report.

Usage: python -m coverage.code_cov_summary <merged.info> [out.md]
"""

from __future__ import annotations

import sys
from pathlib import Path


def summarise(info_path: Path):
    per_file: dict[str, list[int]] = {}   # file -> [found, hit]
    cur = None
    for raw in info_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.startswith("SF:"):
            cur = raw[3:].split("/")[-1]
            per_file.setdefault(cur, [0, 0])
        elif raw.startswith("DA:") and cur is not None:
            line_s, _, count_s = raw[3:].partition(",")
            per_file[cur][0] += 1
            try:
                if int(count_s) > 0:
                    per_file[cur][1] += 1
            except ValueError:
                pass
    return per_file


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: code_cov_summary <merged.info> [out.md]", file=sys.stderr)
        return 2
    info = Path(argv[0])
    if not info.exists():
        print(f"no coverage info at {info}", file=sys.stderr)
        return 1
    per_file = summarise(info)
    tot_f = sum(v[0] for v in per_file.values())
    tot_h = sum(v[1] for v in per_file.values())
    pct = (100.0 * tot_h / tot_f) if tot_f else 0.0

    lines = [
        "# Verilator Line Coverage (owned RTL)",
        "",
        f"- Total: {tot_h}/{tot_f} lines = **{pct:.1f}%**",
        "- Metric: line coverage (toggle excluded — memory/bus-dominated, not a meaningful gate here)",
        "",
        "| File | Lines hit/found | % |",
        "| --- | ---: | ---: |",
    ]
    for f in sorted(per_file):
        found, hit = per_file[f]
        p = (100.0 * hit / found) if found else 0.0
        lines.append(f"| `{f}` | {hit}/{found} | {p:.0f}% |")
    report = "\n".join(lines) + "\n"

    print(f"\nTOTAL LINE COVERAGE: {tot_h}/{tot_f} = {pct:.1f}%")
    for f in sorted(per_file):
        found, hit = per_file[f]
        p = (100.0 * hit / found) if found else 0.0
        print(f"  {f:30s} {hit:5d}/{found:<5d} {p:5.0f}%")

    if len(argv) > 1:
        Path(argv[1]).write_text(report, encoding="utf-8")
        print(f"\nWrote {argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
