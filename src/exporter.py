from __future__ import annotations

import base64
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Sequence

from .tester import RoundSummary, TestResult, TestStats

MAX_FAILED_DETAIL = 500


def sort_working(results: Sequence[TestResult]) -> List[TestResult]:
    working = [r for r in results if r.success]
    working.sort(key=lambda r: r.latency_ms)
    return working


def write_working_configs(
    results: Sequence[TestResult],
    path: Path | str,
    *,
    only_working: bool = True,
) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    items = sort_working(results) if only_working else list(results)
    lines = [r.raw for r in items if r.raw]
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    return path


def build_subscription_b64(results: Sequence[TestResult]) -> str:
    working = sort_working(results)
    body = "\n".join(r.raw for r in working if r.raw)
    if not body:
        return ""
    return base64.b64encode(body.encode("utf-8")).decode("ascii")


def write_subscription_b64(
    results: Sequence[TestResult],
    path: Path | str,
) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    b64 = build_subscription_b64(results)
    path.write_text(b64 + ("\n" if b64 else ""), encoding="utf-8")
    return path


def write_report(
    results: Sequence[TestResult],
    stats: TestStats,
    path: Path | str,
    *,
    source_urls: Optional[Sequence[str]] = None,
    extra_notes: Optional[Sequence[str]] = None,
    round_summaries: Optional[Sequence[RoundSummary]] = None,
) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    working = sort_working(results)
    failed = [r for r in results if not r.success]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    lines: List[str] = []
    lines.append("=" * 60)
    lines.append("Velo test report")
    lines.append("=" * 60)
    lines.append("Generated:     " + now)
    if stats.initial_total:
        lines.append("Initial total: %d" % stats.initial_total)
    lines.append("Total tested:  %d" % stats.tested)
    lines.append("Working:       %d" % stats.working)
    lines.append("Failed:        %d" % stats.failed)
    if stats.rounds and stats.rounds > 1:
        lines.append(
            "Stability:     %d/%d cycles completed"
            % (stats.rounds_completed, stats.rounds)
        )
    if stats.skipped:
        lines.append("Unsupported:   %d" % stats.skipped)
    lines.append("Avg latency:   %.1f ms" % stats.average_latency_ms)
    if working:
        lines.append("Min latency:   %.1f ms" % min(r.latency_ms for r in working))
        lines.append("Max latency:   %.1f ms" % max(r.latency_ms for r in working))
    lines.append("")

    if round_summaries:
        lines.append("Cycles (each one re-tests only the previous survivors):")
        for s in round_summaries:
            status = "ok" if s.completed else "stopped"
            lines.append(
                "  cycle %d/%d: in=%d survivors=%d eliminated=%d [%s]"
                % (
                    s.round_num,
                    s.total_rounds,
                    s.input_count,
                    s.survivors,
                    s.eliminated,
                    status,
                )
            )
        lines.append("")

    if source_urls:
        lines.append("Sources: %d" % len(source_urls))
        lines.append("")

    if extra_notes:
        lines.append("Notes:")
        for n in extra_notes:
            lines.append("  - " + n)
        lines.append("")

    lines.append("-" * 60)
    lines.append("Working configs (%d), sorted by latency:" % len(working))
    lines.append("-" * 60)
    for i, r in enumerate(working, 1):
        lines.append(
            "%4d. [%-8s] %8.1f ms  %-40s  %s:%d"
            % (i, r.protocol, r.latency_ms, r.name[:40], r.server, r.port)
        )

    if failed:
        lines.append("")
        lines.append("-" * 60)
        lines.append("Failed configs (%d):" % len(failed))
        lines.append("-" * 60)
        for i, r in enumerate(failed[:MAX_FAILED_DETAIL], 1):
            lines.append(
                "%4d. [%-8s] %-40s  %s"
                % (i, r.protocol, r.name[:40], (r.error or "")[:80])
            )
        if len(failed) > MAX_FAILED_DETAIL:
            lines.append("... and %d more" % (len(failed) - MAX_FAILED_DETAIL))

    lines.append("")
    lines.append("=" * 60)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def default_output_paths(output_dir: Path | str) -> dict:
    output_dir = Path(output_dir)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return {
        "configs": output_dir / ("working_configs_%s.txt" % stamp),
        "report": output_dir / ("report_%s.txt" % stamp),
        "subscription": output_dir / ("subscription_%s.txt" % stamp),
    }
