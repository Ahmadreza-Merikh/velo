from __future__ import annotations

import logging
import threading
import tkinter.filedialog as filedialog
import tkinter.messagebox as messagebox
from pathlib import Path
from typing import List, Optional

import customtkinter as ctk

from . import __version__
from .defaults import builtin_source_count, builtin_sources
from .exporter import (
    build_subscription_b64,
    default_output_paths,
    write_report,
    write_subscription_b64,
    write_working_configs,
)
from .subscription import fetch_all_subscriptions, parse_url_list
from .tester import (
    DEFAULT_CONCURRENCY,
    DEFAULT_CYCLES,
    DEFAULT_TIMEOUT,
    ConfigTester,
    RoundSummary,
    TestResult,
    TestStats,
)
from .xray_manager import ensure_xray, find_xray_binary, xray_version

logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = PROJECT_ROOT / "output"

ctk.set_appearance_mode("System")
ctk.set_default_color_theme("blue")


class App(ctk.CTk):
    def __init__(self) -> None:
        super().__init__()

        self.title("Velo Tester  v" + __version__)
        self.geometry("940x820")
        self.minsize(820, 680)

        self._worker: Optional[threading.Thread] = None
        self._tester: Optional[ConfigTester] = None
        self._running = False
        self._results: List[TestResult] = []
        self._stats = TestStats()
        self._round_summaries: List[RoundSummary] = []
        self._source_urls: List[str] = []
        self._xray_path: Optional[Path] = None
        self._subscription_b64 = ""
        self._lock = threading.Lock()

        self._build_ui()
        self.after(100, self._bootstrap_xray)

    def _build_ui(self) -> None:
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(3, weight=1)

        header = ctk.CTkFrame(self, fg_color="transparent")
        header.grid(row=0, column=0, sticky="ew", padx=16, pady=(16, 8))
        header.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            header,
            text="Velo Tester",
            font=ctk.CTkFont(size=22, weight="bold"),
        ).grid(row=0, column=0, sticky="w")

        self.xray_status_label = ctk.CTkLabel(
            header,
            text="xray-core: checking",
            font=ctk.CTkFont(size=12),
            text_color=("gray40", "gray60"),
        )
        self.xray_status_label.grid(row=1, column=0, sticky="w", pady=(2, 0))

        input_frame = ctk.CTkFrame(self)
        input_frame.grid(row=1, column=0, sticky="ew", padx=16, pady=8)
        input_frame.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            input_frame,
            text="Your subscription links (one per line, raw share links also work)",
            font=ctk.CTkFont(size=13, weight="bold"),
        ).grid(row=0, column=0, sticky="w", padx=12, pady=(12, 4))

        self.use_builtin_var = ctk.BooleanVar(value=True)
        self.use_builtin_check = ctk.CTkCheckBox(
            input_frame,
            text="Search built-in sources (%d)" % builtin_source_count(),
            variable=self.use_builtin_var,
        )
        self.use_builtin_check.grid(
            row=0, column=1, sticky="e", padx=(4, 12), pady=(12, 4)
        )

        self.url_text = ctk.CTkTextbox(input_frame, height=90, wrap="none")
        self.url_text.grid(
            row=1, column=0, columnspan=2, sticky="ew", padx=12, pady=(0, 12)
        )

        settings = ctk.CTkFrame(self)
        settings.grid(row=2, column=0, sticky="ew", padx=16, pady=4)
        settings.grid_columnconfigure(7, weight=1)

        ctk.CTkLabel(settings, text="Concurrency:").grid(
            row=0, column=0, padx=(12, 4), pady=12, sticky="w"
        )
        self.concurrency_var = ctk.StringVar(value=str(DEFAULT_CONCURRENCY))
        ctk.CTkEntry(settings, textvariable=self.concurrency_var, width=64).grid(
            row=0, column=1, padx=4, pady=12
        )

        ctk.CTkLabel(settings, text="Timeout (s):").grid(
            row=0, column=2, padx=(12, 4), pady=12, sticky="w"
        )
        self.timeout_var = ctk.StringVar(value=str(int(DEFAULT_TIMEOUT)))
        ctk.CTkEntry(settings, textvariable=self.timeout_var, width=64).grid(
            row=0, column=3, padx=4, pady=12
        )

        ctk.CTkLabel(settings, text="Cycles:").grid(
            row=0, column=4, padx=(12, 4), pady=12, sticky="w"
        )
        self.cycles_var = ctk.StringVar(value=str(DEFAULT_CYCLES))
        ctk.CTkEntry(settings, textvariable=self.cycles_var, width=64).grid(
            row=0, column=5, padx=4, pady=12
        )

        self.gen_sub_var = ctk.BooleanVar(value=True)
        ctk.CTkCheckBox(
            settings,
            text="Save base64 file",
            variable=self.gen_sub_var,
        ).grid(row=0, column=6, padx=(12, 12), pady=12, sticky="w")

        ctk.CTkLabel(
            settings,
            text="Each cycle re-tests only the survivors of the previous one",
            font=ctk.CTkFont(size=11),
            text_color=("gray45", "gray55"),
        ).grid(row=1, column=0, columnspan=7, sticky="w", padx=12, pady=(0, 8))

        progress_frame = ctk.CTkFrame(self)
        progress_frame.grid(row=3, column=0, sticky="nsew", padx=16, pady=8)
        progress_frame.grid_columnconfigure(0, weight=1)
        progress_frame.grid_rowconfigure(4, weight=1)

        counters = ctk.CTkFrame(progress_frame, fg_color="transparent")
        counters.grid(row=0, column=0, sticky="ew", padx=12, pady=(12, 4))
        for i in range(4):
            counters.grid_columnconfigure(i, weight=1)

        self.lbl_total = self._counter_card(counters, 0, "Total", "0")
        self.lbl_tested = self._counter_card(counters, 1, "Tested", "0")
        self.lbl_working = self._counter_card(
            counters, 2, "Working", "0", accent="#2ecc71"
        )
        self.lbl_failed = self._counter_card(
            counters, 3, "Failed", "0", accent="#e74c3c"
        )

        self.progress = ctk.CTkProgressBar(progress_frame)
        self.progress.grid(row=1, column=0, sticky="ew", padx=12, pady=8)
        self.progress.set(0)

        self.status_label = ctk.CTkLabel(
            progress_frame,
            text="Ready.",
            anchor="w",
            font=ctk.CTkFont(size=12),
        )
        self.status_label.grid(row=2, column=0, sticky="ew", padx=12, pady=(0, 4))

        ctk.CTkLabel(
            progress_frame,
            text="Live results",
            font=ctk.CTkFont(size=12, weight="bold"),
            anchor="w",
        ).grid(row=3, column=0, sticky="nw", padx=12, pady=(8, 0))

        self.log_box = ctk.CTkTextbox(progress_frame, height=150, wrap="word")
        self.log_box.grid(row=4, column=0, sticky="nsew", padx=12, pady=(4, 8))
        self.log_box.configure(state="disabled")

        sub_frame = ctk.CTkFrame(self)
        sub_frame.grid(row=4, column=0, sticky="ew", padx=16, pady=(0, 8))
        sub_frame.grid_columnconfigure(0, weight=1)

        ctk.CTkLabel(
            sub_frame,
            text="Result subscription (base64)",
            font=ctk.CTkFont(size=12, weight="bold"),
            anchor="w",
        ).grid(row=0, column=0, columnspan=2, sticky="w", padx=12, pady=(10, 4))

        self.sub_text = ctk.CTkTextbox(sub_frame, height=56, wrap="char")
        self.sub_text.grid(row=1, column=0, sticky="ew", padx=(12, 8), pady=(0, 12))
        self.sub_text.configure(state="disabled")

        self.copy_sub_btn = ctk.CTkButton(
            sub_frame,
            text="Copy",
            width=120,
            height=56,
            command=self._on_copy_subscription,
            state="disabled",
        )
        self.copy_sub_btn.grid(row=1, column=1, padx=(0, 12), pady=(0, 12), sticky="ns")

        btn_row = ctk.CTkFrame(self, fg_color="transparent")
        btn_row.grid(row=5, column=0, sticky="ew", padx=16, pady=(4, 16))
        btn_row.grid_columnconfigure(4, weight=1)

        self.start_btn = ctk.CTkButton(
            btn_row, text="Start", width=120, command=self._on_start, height=36
        )
        self.start_btn.grid(row=0, column=0, padx=(0, 8))

        self.stop_btn = ctk.CTkButton(
            btn_row,
            text="Stop",
            width=120,
            command=self._on_stop,
            height=36,
            state="disabled",
            fg_color="#c0392b",
            hover_color="#a93226",
        )
        self.stop_btn.grid(row=0, column=1, padx=8)

        self.save_btn = ctk.CTkButton(
            btn_row,
            text="Save results",
            width=140,
            command=self._on_save,
            height=36,
            state="disabled",
        )
        self.save_btn.grid(row=0, column=2, padx=8)

        self.clear_btn = ctk.CTkButton(
            btn_row,
            text="Clear log",
            width=100,
            command=self._clear_log,
            height=36,
            fg_color=("gray70", "gray35"),
            hover_color=("gray60", "gray40"),
        )
        self.clear_btn.grid(row=0, column=3, padx=8)

        self.avg_label = ctk.CTkLabel(
            btn_row, text="Avg latency: -", font=ctk.CTkFont(size=13)
        )
        self.avg_label.grid(row=0, column=4, sticky="e", padx=8)

    def _counter_card(self, parent, col, title, value, accent=None):
        frame = ctk.CTkFrame(parent)
        frame.grid(row=0, column=col, sticky="ew", padx=6, pady=4)
        ctk.CTkLabel(
            frame,
            text=title,
            font=ctk.CTkFont(size=11),
            text_color=("gray40", "gray60"),
        ).pack(pady=(8, 0))
        lbl = ctk.CTkLabel(
            frame,
            text=value,
            font=ctk.CTkFont(size=24, weight="bold"),
            text_color=accent if accent else None,
        )
        lbl.pack(pady=(0, 8))
        return lbl

    def _bootstrap_xray(self) -> None:
        def work():
            try:
                path = find_xray_binary()
                if path is None:
                    self._ui(
                        lambda: self.xray_status_label.configure(
                            text="xray-core: downloading"
                        )
                    )
                    path = ensure_xray(
                        progress_cb=lambda m: self._ui(
                            lambda msg=m: self.xray_status_label.configure(text=msg)
                        )
                    )
                ver = xray_version(path)
                self._xray_path = path
                label = "xray-core: ready" + (("  " + ver) if ver else "")
                self._ui(lambda: self.xray_status_label.configure(text=label))
            except Exception as exc:
                logger.exception("xray bootstrap failed")
                self._ui(
                    lambda: self.xray_status_label.configure(
                        text="xray-core: error, " + str(exc)
                    )
                )

        threading.Thread(target=work, daemon=True).start()

    def _ui(self, fn) -> None:
        try:
            self.after(0, fn)
        except Exception:
            pass

    def _collect_sources(self) -> List[str]:
        urls = parse_url_list(self.url_text.get("1.0", "end"))
        if self.use_builtin_var.get():
            known = set(urls)
            for u in builtin_sources():
                if u not in known:
                    known.add(u)
                    urls.append(u)
        return urls

    def _on_start(self) -> None:
        if self._running:
            return

        urls = self._collect_sources()
        if not urls:
            messagebox.showwarning(
                "No sources",
                "Add at least one subscription link, or enable the built-in sources.",
            )
            return

        if not self._xray_path:
            messagebox.showwarning(
                "xray-core missing",
                "xray-core is not ready yet.",
            )
            return

        try:
            concurrency = int(self.concurrency_var.get().strip())
            timeout = float(self.timeout_var.get().strip())
            cycles = int(self.cycles_var.get().strip())
            if concurrency < 1 or concurrency > 500:
                raise ValueError("concurrency must be between 1 and 500")
            if timeout < 1 or timeout > 120:
                raise ValueError("timeout must be between 1 and 120 seconds")
            if cycles < 1:
                raise ValueError("cycles must be at least 1")
        except ValueError as exc:
            messagebox.showerror("Invalid settings", str(exc))
            return

        self._results = []
        self._stats = TestStats()
        self._round_summaries = []
        self._source_urls = urls
        self._subscription_b64 = ""
        self._running = True
        self.start_btn.configure(state="disabled")
        self.stop_btn.configure(state="normal")
        self.save_btn.configure(state="disabled")
        self.copy_sub_btn.configure(state="disabled")
        self._set_subscription_text("")
        self._set_counters(0, 0, 0, 0)
        self.progress.set(0)
        self.avg_label.configure(text="Avg latency: -")
        self._append_log(
            "starting: %d sources, concurrency=%d, timeout=%ss, cycles=%d"
            % (len(urls), concurrency, timeout, cycles)
        )
        self.status_label.configure(text="Fetching sources")

        self._worker = threading.Thread(
            target=self._run_pipeline,
            args=(urls, concurrency, timeout, cycles),
            daemon=True,
        )
        self._worker.start()

    def _on_stop(self) -> None:
        if self._tester:
            self._tester.stop()
        self.status_label.configure(text="Stopping")
        self._append_log("stop requested")

    def _on_save(self) -> None:
        if not self._results:
            messagebox.showinfo("Nothing to save", "No results yet.")
            return

        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

        directory = filedialog.askdirectory(
            title="Choose output folder",
            initialdir=str(OUTPUT_DIR),
        )
        if not directory:
            return

        paths = default_output_paths(Path(directory))

        try:
            cfg_path = write_working_configs(self._results, paths["configs"])
            rep_path = write_report(
                self._results,
                self._stats,
                paths["report"],
                source_urls=self._source_urls,
                round_summaries=self._round_summaries,
            )
            sub_path = None
            if self._subscription_b64 or any(r.success for r in self._results):
                sub_path = write_subscription_b64(self._results, paths["subscription"])

            msg = "Configs:\n%s\n\nReport:\n%s" % (cfg_path, rep_path)
            if sub_path:
                msg += "\n\nSubscription:\n%s" % sub_path
            messagebox.showinfo("Saved", msg)
            self._append_log("results saved to " + directory)
        except Exception as exc:
            messagebox.showerror("Save failed", str(exc))

    def _on_copy_subscription(self) -> None:
        b64 = self._subscription_b64.strip()
        if not b64:
            messagebox.showinfo("Nothing to copy", "No working configs.")
            return
        try:
            self.clipboard_clear()
            self.clipboard_append(b64)
            self.update_idletasks()
            self.status_label.configure(text="Copied to clipboard")
        except Exception as exc:
            messagebox.showerror("Copy failed", str(exc))

    def _clear_log(self) -> None:
        self.log_box.configure(state="normal")
        self.log_box.delete("1.0", "end")
        self.log_box.configure(state="disabled")

    def _run_pipeline(
        self,
        urls: List[str],
        concurrency: int,
        timeout: float,
        cycles: int,
    ) -> None:
        try:
            def fetch_progress(idx, total, url):
                self._ui(
                    lambda: self.status_label.configure(
                        text="Fetching source %d/%d" % (idx, total)
                    )
                )

            configs, errors = fetch_all_subscriptions(urls, progress_cb=fetch_progress)
            for err in errors:
                self._ui(lambda e=err: self._append_log("warn: " + e))

            if not configs:
                self._ui(
                    lambda: messagebox.showerror(
                        "No configs", "No proxy configs were found."
                    )
                )
                self._ui(self._finish_idle)
                return

            self._ui(
                lambda: self._append_log(
                    "fetched %d unique configs, testing %d cycles"
                    % (len(configs), cycles)
                )
            )
            self._ui(lambda: self._set_counters(len(configs), 0, 0, 0))

            self._tester = ConfigTester(
                xray_path=self._xray_path,
                timeout=timeout,
                concurrency=concurrency,
            )

            def on_round_start(round_num, total_rounds, count):
                msg = "cycle %d/%d: testing %d configs" % (
                    round_num,
                    total_rounds,
                    count,
                )
                self._ui(lambda m=msg: self._append_log(m))
                self._ui(lambda m=msg: self.status_label.configure(text=m))
                self._ui(lambda c=count: self._set_counters(c, 0, 0, 0))
                self._ui(lambda: self.progress.set(0))

            def on_round_end(summary: RoundSummary):
                if summary.completed:
                    msg = "cycle %d/%d done: %d survivors, %d eliminated" % (
                        summary.round_num,
                        summary.total_rounds,
                        summary.survivors,
                        summary.eliminated,
                    )
                else:
                    msg = "cycle %d/%d stopped" % (
                        summary.round_num,
                        summary.total_rounds,
                    )
                self._ui(lambda m=msg: self._append_log(m))

            def on_result(result, stats, round_num, total_rounds):
                total = stats.total or 1
                overall = ((round_num - 1) + (stats.tested / total)) / max(
                    1, total_rounds
                )

                def update():
                    self._set_counters(
                        stats.total, stats.tested, stats.working, stats.failed
                    )
                    self.progress.set(min(1.0, overall))
                    self.status_label.configure(
                        text="cycle %d/%d: %d/%d tested"
                        % (round_num, total_rounds, stats.tested, stats.total)
                    )
                    if stats.latencies:
                        self.avg_label.configure(
                            text="Avg latency: %.0f ms" % stats.average_latency_ms
                        )
                    if result.success:
                        self._append_log(
                            "  ok  %6.0f ms  [%s] %s"
                            % (result.latency_ms, result.protocol, result.name[:50])
                        )

                self._ui(update)

            results, stats, summaries = self._tester.test_with_retries(
                configs,
                rounds=cycles,
                on_result=on_result,
                on_round_start=on_round_start,
                on_round_end=on_round_end,
            )

            with self._lock:
                self._results = results
                self._stats = stats
                self._round_summaries = summaries

            b64 = build_subscription_b64(results) if results else ""
            self._subscription_b64 = b64

            OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
            paths = default_output_paths(OUTPUT_DIR)
            write_working_configs(results, paths["configs"])
            write_report(
                results,
                stats,
                paths["report"],
                source_urls=urls,
                extra_notes=errors,
                round_summaries=summaries,
            )
            if self.gen_sub_var.get() and b64:
                write_subscription_b64(results, paths["subscription"])

            done = "done: %d working of %d, avg %.0f ms" % (
                stats.working,
                stats.initial_total or stats.total,
                stats.average_latency_ms,
            )
            self._ui(lambda: self._append_log(done))
            self._ui(lambda: self.status_label.configure(text=done))
            self._ui(
                lambda: self._set_counters(
                    stats.initial_total or stats.total,
                    stats.tested,
                    stats.working,
                    stats.failed,
                )
            )
            self._ui(lambda: self.progress.set(1.0 if stats.total else 0))
            self._ui(lambda b=b64: self._set_subscription_text(b))

        except Exception as exc:
            logger.exception("pipeline failed")
            self._ui(lambda: self._append_log("error: " + str(exc)))
            self._ui(lambda: messagebox.showerror("Error", str(exc)))
        finally:
            self._ui(self._finish_idle)

    def _finish_idle(self) -> None:
        self._running = False
        self.start_btn.configure(state="normal")
        self.stop_btn.configure(state="disabled")
        if self._results:
            self.save_btn.configure(state="normal")
        if self._subscription_b64:
            self.copy_sub_btn.configure(state="normal")

    def _set_counters(self, total, tested, working, failed) -> None:
        self.lbl_total.configure(text=str(total))
        self.lbl_tested.configure(text=str(tested))
        self.lbl_working.configure(text=str(working))
        self.lbl_failed.configure(text=str(failed))

    def _set_subscription_text(self, text: str) -> None:
        self.sub_text.configure(state="normal")
        self.sub_text.delete("1.0", "end")
        if text:
            self.sub_text.insert("1.0", text)
        self.sub_text.configure(state="disabled")

    def _append_log(self, line: str) -> None:
        self.log_box.configure(state="normal")
        self.log_box.insert("end", line + "\n")
        self.log_box.see("end")
        self.log_box.configure(state="disabled")


def run_app() -> None:
    App().mainloop()
