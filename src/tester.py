from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import tempfile
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence

from .parser import ParsedConfig, build_test_config, parse_config

logger = logging.getLogger(__name__)

DEFAULT_TEST_URLS = (
    "http://www.gstatic.com/generate_204",
    "http://cp.cloudflare.com/generate_204",
    "http://connectivitycheck.gstatic.com/generate_204",
)

DEFAULT_TIMEOUT = 10.0
DEFAULT_CONCURRENCY = 50
DEFAULT_CYCLES = 20
XRAY_BOOT_WAIT = 0.35
PORT_RANGE_START = 20_000
PORT_RANGE_SIZE = 10_000


@dataclass
class TestResult:
    raw: str
    name: str
    protocol: str
    success: bool
    latency_ms: float = 0.0
    error: str = ""
    server: str = ""
    port: int = 0


@dataclass
class TestStats:
    total: int = 0
    tested: int = 0
    working: int = 0
    failed: int = 0
    skipped: int = 0
    latencies: List[float] = field(default_factory=list)
    rounds: int = 1
    rounds_completed: int = 0
    initial_total: int = 0

    @property
    def average_latency_ms(self) -> float:
        if not self.latencies:
            return 0.0
        return sum(self.latencies) / len(self.latencies)


@dataclass
class RoundSummary:
    round_num: int
    total_rounds: int
    input_count: int
    survivors: int
    eliminated: int
    completed: bool = True


class PortPool:
    def __init__(self, start: int = PORT_RANGE_START, size: int = PORT_RANGE_SIZE):
        self._start = start
        self._size = size
        self._next = 0
        self._lock = threading.Lock()
        self._free: list[int] = []

    def acquire(self) -> int:
        with self._lock:
            if self._free:
                return self._free.pop()
            port = self._start + (self._next % self._size)
            self._next += 1
            return port

    def release(self, port: int) -> None:
        with self._lock:
            self._free.append(port)


class ConfigTester:
    def __init__(
        self,
        xray_path: Path | str,
        timeout: float = DEFAULT_TIMEOUT,
        concurrency: int = DEFAULT_CONCURRENCY,
        test_urls: Sequence[str] = DEFAULT_TEST_URLS,
        work_dir: Optional[Path] = None,
    ):
        self.xray_path = Path(xray_path)
        self.timeout = float(timeout)
        self.concurrency = max(1, int(concurrency))
        self.test_urls = list(test_urls) if test_urls else list(DEFAULT_TEST_URLS)
        self.work_dir = Path(work_dir) if work_dir else None

        self._stop = threading.Event()
        self._ports = PortPool()
        self._curl = shutil.which("curl") or "/usr/bin/curl"

        if not self.xray_path.is_file():
            raise FileNotFoundError("xray binary not found: " + str(self.xray_path))
        if not os.access(self.xray_path, os.X_OK):
            raise PermissionError("xray binary not executable: " + str(self.xray_path))

    def stop(self) -> None:
        self._stop.set()

    def reset_stop(self) -> None:
        self._stop.clear()

    @property
    def stopped(self) -> bool:
        return self._stop.is_set()

    def test_one(self, parsed: ParsedConfig) -> TestResult:
        if self._stop.is_set():
            return self._fail(parsed, "cancelled")

        if not parsed.ok or not parsed.outbound:
            return self._fail(parsed, parsed.error or "parse failed")

        local_port = self._ports.acquire()
        tmp_dir = None
        proc: Optional[subprocess.Popen] = None

        try:
            tmp_dir = tempfile.mkdtemp(prefix="xray_test_", dir=self.work_dir)
            cfg_path = Path(tmp_dir) / "config.json"
            full_cfg = build_test_config(parsed.outbound, local_port)
            cfg_path.write_text(
                json.dumps(full_cfg, ensure_ascii=False),
                encoding="utf-8",
            )

            proc = subprocess.Popen(
                [str(self.xray_path), "run", "-c", str(cfg_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )

            boot_deadline = time.monotonic() + XRAY_BOOT_WAIT
            while time.monotonic() < boot_deadline:
                if self._stop.is_set():
                    return self._fail(parsed, "cancelled")
                if proc.poll() is not None:
                    return self._fail(
                        parsed, "xray exited early (code %s)" % proc.returncode
                    )
                time.sleep(0.05)

            if proc.poll() is not None:
                return self._fail(
                    parsed, "xray exited early (code %s)" % proc.returncode
                )

            latency_ms, err = self._probe_via_socks(local_port)
            if err is None:
                return TestResult(
                    raw=parsed.raw,
                    name=parsed.name,
                    protocol=parsed.protocol,
                    success=True,
                    latency_ms=latency_ms,
                    server=parsed.server,
                    port=parsed.port,
                )
            return self._fail(parsed, err)

        except Exception as exc:
            return self._fail(parsed, str(exc))
        finally:
            self._cleanup_proc(proc)
            self._ports.release(local_port)
            if tmp_dir:
                shutil.rmtree(tmp_dir, ignore_errors=True)

    def _fail(self, parsed: ParsedConfig, error: str) -> TestResult:
        return TestResult(
            raw=parsed.raw,
            name=parsed.name,
            protocol=parsed.protocol,
            success=False,
            error=error,
            server=parsed.server,
            port=parsed.port,
        )

    def _probe_via_socks(self, local_port: int) -> tuple[float, Optional[str]]:
        remaining = self.timeout
        last_err = "no test url succeeded"

        for url in self.test_urls:
            if self._stop.is_set():
                return 0.0, "cancelled"
            if remaining <= 0.5:
                break

            url_timeout = min(remaining, self.timeout)
            t0 = time.monotonic()
            try:
                cmd = [
                    self._curl,
                    "-sS",
                    "-o",
                    "/dev/null",
                    "-x",
                    "socks5h://127.0.0.1:%d" % local_port,
                    "--connect-timeout",
                    str(max(1, int(url_timeout))),
                    "-m",
                    str(max(1, int(url_timeout))),
                    "-w",
                    "%{http_code} %{time_total}",
                    url,
                ]
                completed = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=url_timeout + 2,
                )
                elapsed = time.monotonic() - t0
                remaining -= elapsed

                if completed.returncode != 0:
                    last_err = (
                        completed.stderr or completed.stdout or "curl failed"
                    ).strip()
                    last_err = last_err[:200] or "curl exit %d" % completed.returncode
                    continue

                parts = (completed.stdout or "").strip().split()
                if len(parts) >= 2:
                    code_s, time_s = parts[0], parts[1]
                elif len(parts) == 1:
                    code_s, time_s = parts[0], str(elapsed)
                else:
                    last_err = "empty curl output"
                    continue

                try:
                    code = int(code_s)
                except ValueError:
                    code = 0
                try:
                    total = float(time_s)
                except ValueError:
                    total = elapsed

                if 200 <= code < 400:
                    return total * 1000.0, None

                last_err = "http %d" % code
            except subprocess.TimeoutExpired:
                remaining = 0
                last_err = "timeout"
            except Exception as exc:
                last_err = str(exc)
                remaining -= time.monotonic() - t0

        return 0.0, last_err

    @staticmethod
    def _cleanup_proc(proc: Optional[subprocess.Popen]) -> None:
        if proc is None:
            return
        try:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, 15)
                except Exception:
                    proc.terminate()
                try:
                    proc.wait(timeout=1.5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(proc.pid, 9)
                    except Exception:
                        proc.kill()
                    proc.wait(timeout=1)
        except Exception:
            pass

    def test_batch(
        self,
        share_links: Sequence[str],
        on_result: Optional[Callable[[TestResult, TestStats], None]] = None,
        on_progress: Optional[Callable[[TestStats], None]] = None,
        *,
        clear_stop: bool = True,
    ) -> tuple[List[TestResult], TestStats]:
        if clear_stop:
            self.reset_stop()
        stats = TestStats(total=len(share_links), initial_total=len(share_links))
        results: List[TestResult] = []
        results_lock = threading.Lock()

        parsed_list: List[ParsedConfig] = []
        for link in share_links:
            if self._stop.is_set():
                break
            p = parse_config(link)
            if not p.ok or not p.outbound:
                stats.skipped += 1
                stats.tested += 1
                stats.failed += 1
                tr = TestResult(
                    raw=p.raw,
                    name=p.name,
                    protocol=p.protocol,
                    success=False,
                    error=p.error or "unsupported",
                    server=p.server,
                    port=p.port,
                )
                with results_lock:
                    results.append(tr)
                if on_result:
                    on_result(tr, stats)
                if on_progress:
                    on_progress(stats)
            else:
                parsed_list.append(p)

        def _worker(p: ParsedConfig) -> TestResult:
            if self._stop.is_set():
                return self._fail(p, "cancelled")
            return self.test_one(p)

        if not parsed_list or self._stop.is_set():
            return results, stats

        with ThreadPoolExecutor(max_workers=self.concurrency) as pool:
            futures: Dict[Future, ParsedConfig] = {
                pool.submit(_worker, p): p for p in parsed_list
            }

            for fut in as_completed(futures):
                if self._stop.is_set():
                    for f in futures:
                        f.cancel()
                    break
                try:
                    tr = fut.result()
                except Exception as exc:
                    tr = self._fail(futures[fut], str(exc))

                with results_lock:
                    results.append(tr)
                    stats.tested += 1
                    if tr.success:
                        stats.working += 1
                        stats.latencies.append(tr.latency_ms)
                    else:
                        stats.failed += 1

                if on_result:
                    on_result(tr, stats)
                if on_progress:
                    on_progress(stats)

        return results, stats

    def test_with_retries(
        self,
        share_links: Sequence[str],
        rounds: int = 1,
        on_result: Optional[Callable[[TestResult, TestStats, int, int], None]] = None,
        on_progress: Optional[Callable[[TestStats, int, int], None]] = None,
        on_round_start: Optional[Callable[[int, int, int], None]] = None,
        on_round_end: Optional[Callable[[RoundSummary], None]] = None,
    ) -> tuple[List[TestResult], TestStats, List[RoundSummary]]:
        rounds = max(1, int(rounds))
        self.reset_stop()

        initial_total = len(share_links)
        latency_history: Dict[str, List[float]] = {}
        last_ok: Dict[str, TestResult] = {}

        current_links: List[str] = list(share_links)
        summaries: List[RoundSummary] = []
        stable_links: List[str] = []
        rounds_completed = 0

        for round_num in range(1, rounds + 1):
            if self._stop.is_set() or not current_links:
                break

            if on_round_start:
                on_round_start(round_num, rounds, len(current_links))

            def _wrap_result(tr: TestResult, st: TestStats, rn=round_num, trn=rounds):
                if on_result:
                    on_result(tr, st, rn, trn)

            def _wrap_progress(st: TestStats, rn=round_num, trn=rounds):
                if on_progress:
                    on_progress(st, rn, trn)

            batch_results, _ = self.test_batch(
                current_links,
                on_result=_wrap_result if on_result else None,
                on_progress=_wrap_progress if on_progress else None,
                clear_stop=False,
            )

            if self._stop.is_set():
                summaries.append(
                    RoundSummary(
                        round_num=round_num,
                        total_rounds=rounds,
                        input_count=len(current_links),
                        survivors=0,
                        eliminated=0,
                        completed=False,
                    )
                )
                if on_round_end:
                    on_round_end(summaries[-1])
                break

            survivors = [r for r in batch_results if r.success]
            for r in survivors:
                latency_history.setdefault(r.raw, []).append(r.latency_ms)
                last_ok[r.raw] = r

            survivor_links = [r.raw for r in survivors]
            summary = RoundSummary(
                round_num=round_num,
                total_rounds=rounds,
                input_count=len(current_links),
                survivors=len(survivor_links),
                eliminated=len(current_links) - len(survivor_links),
                completed=True,
            )
            summaries.append(summary)
            rounds_completed = round_num
            stable_links = survivor_links
            current_links = survivor_links

            if on_round_end:
                on_round_end(summary)

            if not current_links:
                break

        final_results: List[TestResult] = []
        for link in stable_links:
            base = last_ok.get(link)
            if not base:
                continue
            samples = latency_history.get(link) or [base.latency_ms]
            final_results.append(
                TestResult(
                    raw=base.raw,
                    name=base.name,
                    protocol=base.protocol,
                    success=True,
                    latency_ms=sum(samples) / len(samples),
                    server=base.server,
                    port=base.port,
                )
            )
        final_results.sort(key=lambda r: r.latency_ms)

        final_stats = TestStats(
            total=initial_total,
            tested=initial_total,
            working=len(final_results),
            failed=max(0, initial_total - len(final_results)),
            latencies=[r.latency_ms for r in final_results],
            rounds=rounds,
            rounds_completed=rounds_completed,
            initial_total=initial_total,
        )
        return final_results, final_stats, summaries
