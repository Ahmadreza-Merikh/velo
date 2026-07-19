#!/usr/bin/env python3
from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def setup_logging(verbose: bool = False) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )


def run_cli(args: argparse.Namespace) -> int:
    from src.defaults import builtin_sources
    from src.exporter import (
        default_output_paths,
        write_report,
        write_subscription_b64,
        write_working_configs,
    )
    from src.subscription import fetch_all_subscriptions, parse_url_list
    from src.tester import ConfigTester
    from src.xray_manager import ensure_xray

    urls = list(args.url or [])
    if args.url_file:
        urls.extend(parse_url_list(Path(args.url_file).read_text(encoding="utf-8")))
    if not args.no_builtin:
        known = set(urls)
        for u in builtin_sources():
            if u not in known:
                known.add(u)
                urls.append(u)
    if not urls:
        print("error: no sources", file=sys.stderr)
        return 2

    xray = ensure_xray(progress_cb=print)

    print("fetching %d sources" % len(urls))
    configs, errors = fetch_all_subscriptions(urls)
    for e in errors:
        print("  warn: " + e, file=sys.stderr)
    print("found %d configs" % len(configs))
    if not configs:
        return 1

    tester = ConfigTester(
        xray_path=xray,
        timeout=args.timeout,
        concurrency=args.concurrency,
    )

    def on_round_start(round_num, total_rounds, count):
        print("\ncycle %d/%d: testing %d configs" % (round_num, total_rounds, count))

    def on_round_end(summary):
        if summary.completed:
            print(
                "  cycle %d done: %d survivors, %d eliminated"
                % (summary.round_num, summary.survivors, summary.eliminated)
            )
        else:
            print("  cycle %d stopped" % summary.round_num)

    def on_progress(stats, round_num, total_rounds):
        print(
            "\r  c%d/%d  tested=%d/%d  ok=%d  fail=%d  avg=%.0fms"
            % (
                round_num,
                total_rounds,
                stats.tested,
                stats.total,
                stats.working,
                stats.failed,
                stats.average_latency_ms,
            ),
            end="",
            flush=True,
        )

    results, stats, summaries = tester.test_with_retries(
        configs,
        rounds=max(1, int(args.cycles)),
        on_progress=on_progress,
        on_round_start=on_round_start,
        on_round_end=on_round_end,
    )
    print()

    out_dir = Path(args.output or (ROOT / "output"))
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = default_output_paths(out_dir)

    write_working_configs(results, paths["configs"])
    write_report(
        results,
        stats,
        paths["report"],
        source_urls=urls,
        extra_notes=errors,
        round_summaries=summaries,
    )
    if args.subscription or results:
        write_subscription_b64(results, paths["subscription"])
        print("subscription: %s" % paths["subscription"])

    print("configs: %s" % paths["configs"])
    print("report:  %s" % paths["report"])
    print(
        "%d of %d stable after %d/%d cycles, avg latency %.1f ms"
        % (
            stats.working,
            stats.initial_total or stats.total,
            stats.rounds_completed,
            stats.rounds,
            stats.average_latency_ms,
        )
    )
    return 0 if stats.working else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Fetch proxy subscriptions, test them and keep the working ones."
    )
    parser.add_argument("--cli", action="store_true", help="run headless")
    parser.add_argument("--url", action="append", help="subscription url (repeatable)")
    parser.add_argument("--url-file", help="file with one subscription url per line")
    parser.add_argument(
        "--no-builtin",
        action="store_true",
        help="do not search the built-in sources",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=50,
        help="parallel tests (default 50)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="per config timeout in seconds (default 10)",
    )
    parser.add_argument(
        "--cycles",
        type=int,
        default=20,
        help="test cycles, each one re-tests the previous survivors (default 20)",
    )
    parser.add_argument("--output", help="output directory (default ./output)")
    parser.add_argument(
        "--subscription",
        action="store_true",
        help="always write a base64 subscription file",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")

    args = parser.parse_args(argv)
    setup_logging(args.verbose)

    if args.cli or args.url or args.url_file:
        return run_cli(args)

    from src.gui import run_app

    run_app()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
