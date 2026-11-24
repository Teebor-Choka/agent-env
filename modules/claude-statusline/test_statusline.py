"""Tests for the statusline script. Run: python3 -m unittest discover -s modules/claude-statusline

Statusline stdin fields (https://code.claude.com/docs/en/statusline): session_id, cost.total_cost_usd,
context_window.total_input_tokens, context_window.used_percentage.
"""
import datetime
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "statusline")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def ts(days_ago=0):
    return (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


class Statusline(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.ledger = os.path.join(self.home.name, ".claude", "metrics", "ledger.jsonl")

    def write_ledger(self, rows):
        os.makedirs(os.path.dirname(self.ledger), exist_ok=True)
        with open(self.ledger, "w") as f:
            for row in rows:
                f.write((row if isinstance(row, str) else json.dumps(row)) + "\n")

    def run_script(self, payload, raw=None):
        payload = payload if payload is not None else {}
        r = subprocess.run([sys.executable, SCRIPT], input=raw if raw is not None else json.dumps(payload),
                           capture_output=True, text=True, timeout=10, env={**os.environ, "HOME": self.home.name})
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        return r.stdout

    def plain(self, payload, raw=None):
        return ANSI.sub("", self.run_script(payload, raw)).strip()

    def payload(self, cost=12.34, tokens=450_000, pct=45, session="cur"):
        return {"session_id": session, "cost": {"total_cost_usd": cost},
                "context_window": {"total_input_tokens": tokens, "used_percentage": pct}}

    def test_shows_cost_context_and_today(self):
        self.write_ledger([{"session_id": "o1", "ts_last": ts(), "cost_usd": 40.0},
                           {"session_id": "o2", "ts_last": ts(), "cost_usd": 2.0}])
        out = self.plain(self.payload())
        self.assertIn("$12.34", out)
        self.assertIn("450K", out)
        self.assertIn("today $54.34", out)

    def test_other_days_are_not_in_todays_total(self):
        self.write_ledger([{"session_id": "o1", "ts_last": ts(3), "cost_usd": 99.0}])
        self.assertIn("today $12.34", self.plain(self.payload()))

    def test_live_cost_replaces_the_stale_ledger_row_of_the_same_session(self):
        self.write_ledger([{"session_id": "cur", "ts_last": ts(), "cost_usd": 10.0}])
        self.assertIn("today $12.34", self.plain(self.payload()))

    def test_missing_ledger_prints_cost_and_context_only(self):
        out = self.plain(self.payload())
        self.assertIn("$12.34", out)
        self.assertNotIn("Traceback", out)

    def test_empty_ledger(self):
        self.write_ledger([])
        out = self.plain(self.payload())
        self.assertIn("$12.34", out)

    def test_garbage_ledger_lines_are_skipped(self):
        self.write_ledger(["garbage", "{", json.dumps({"session_id": "o", "ts_last": ts(), "cost_usd": "x"}),
                           {"session_id": "o2", "ts_last": ts(), "cost_usd": 1.0}])
        self.assertIn("today $13.34", self.plain(self.payload()))

    def test_duplicate_ledger_session_counts_once_last_wins(self):
        self.write_ledger([{"session_id": "o", "ts_last": ts(), "cost_usd": 1.0},
                           {"session_id": "o", "ts_last": ts(), "cost_usd": 5.0}])
        self.assertIn("today $17.34", self.plain(self.payload()))

    def write_headroom(self, tokens_saved, percent=None):
        os.makedirs(os.path.join(self.home.name, ".headroom"), exist_ok=True)
        with open(os.path.join(self.home.name, ".headroom", "proxy_savings.json"), "w") as f:
            json.dump({"display_session": {"tokens_saved": tokens_saved,
                                           **({} if percent is None else {"savings_percent": percent})}}, f)

    def write_context_mode(self, rows):
        """rows: (session_id, tool, kind, sandbox_bytes, returned_bytes)."""
        d = os.path.join(self.home.name, ".context-mode", "projects", "p1")
        os.makedirs(d, exist_ok=True)
        db = sqlite3.connect(os.path.join(d, "context.db"))
        db.execute("CREATE TABLE events (session_id TEXT, tool TEXT, kind TEXT, sandbox_bytes INT, returned_bytes INT)")
        db.executemany("INSERT INTO events VALUES (?,?,?,?,?)", rows)
        db.commit()
        db.close()

    def test_headroom_savings_follow_the_context_size(self):
        self.write_headroom(278_926, 0.73)
        out = self.plain(self.payload(tokens=110_000, pct=14))
        self.assertIn("ctx 110K (14%) | hr total -279K (0.7%)", out)

    def test_context_mode_savings_count_this_session_only_in_tokens(self):
        self.write_context_mode([("cur", "ctx_execute", "cmd", 40_000, 400), ("cur", "ctx_stats", "cmd", 9_000, 0),
                                 ("old", "ctx_execute", "cmd", 80_000, 0), ("cur", None, "cmd", 5_000, 0)])
        out = self.plain(self.payload(tokens=110_000, pct=14))
        self.assertIn("cm -10K", out)  # (40_000 - 400) / 4 tokens; ctx_stats, null tool and other sessions excluded

    def test_savings_use_their_own_colours_and_are_omitted_when_zero_or_missing(self):
        self.write_headroom(5_000, 1.25)
        self.write_context_mode([("cur", "ctx_execute", "cmd", 8_000, 0)])
        raw = self.run_script(self.payload(cost=1.0, pct=10))
        self.assertIn("\x1b[36mhr total -5K (1.2%)\x1b[0m", raw)
        self.assertIn("\x1b[35mcm -2K\x1b[0m", raw)
        self.write_headroom(0)
        self.assertNotIn("hr ", self.plain(self.payload()))
        self.assertNotIn("cm ", self.plain(self.payload(session="nobody")))

    def test_context_mode_shows_zero_once_it_recorded_this_session(self):
        self.write_context_mode([("cur", "Bash", "cmd", 155, 155)])
        self.assertIn("| cm -0K", self.plain(self.payload()))
        self.assertNotIn("cm ", self.plain(self.payload(session="other")))

    def test_context_mode_comes_before_headroom(self):
        self.write_headroom(5_000, 1.25)
        self.write_context_mode([("cur", "ctx_execute", "cmd", 8_000, 0)])
        out = self.plain(self.payload(tokens=110_000, pct=14))
        self.assertIn("ctx 110K (14%) | cm -2K | hr total -5K (1.2%)", out)

    def test_headroom_without_a_percentage_shows_only_the_tokens(self):
        self.write_headroom(5_000)
        self.assertIn("hr total -5K |", self.plain(self.payload()) + " |")
        self.assertNotIn("%)", self.plain(self.payload()).split("ctx")[1].split("|")[1])

    def test_red_line_stays_one_colour_with_savings(self):
        self.write_headroom(5_000)
        raw = self.run_script(self.payload(cost=150.0, pct=10))
        self.assertTrue(raw.startswith("\x1b[31m"))
        self.assertNotIn("\x1b[36m", raw)

    def test_damaged_savings_files_are_ignored(self):
        os.makedirs(os.path.join(self.home.name, ".headroom"))
        with open(os.path.join(self.home.name, ".headroom", "proxy_savings.json"), "w") as f:
            f.write("{not json")
        d = os.path.join(self.home.name, ".context-mode", "projects", "p1")
        os.makedirs(d)
        with open(os.path.join(d, "context.db"), "w") as f:
            f.write("not a database")
        out = self.plain(self.payload())
        self.assertIn("ctx 450K", out)
        self.assertNotIn("hr ", out)
        self.assertNotIn("cm ", out)

    def test_red_when_cost_reaches_150(self):
        self.assertIn("\x1b[31m", self.run_script(self.payload(cost=150.0, pct=10)))

    def test_red_when_context_reaches_80_percent(self):
        self.assertIn("\x1b[31m", self.run_script(self.payload(cost=1.0, pct=80)))

    def test_not_red_below_limits(self):
        self.assertNotIn("\x1b[31m", self.run_script(self.payload(cost=149.0, pct=79)))

    def test_null_fields_before_the_first_api_call(self):
        out = self.plain({"session_id": "c", "cost": {"total_cost_usd": 0},
                          "context_window": {"total_input_tokens": 0, "used_percentage": None, "current_usage": None}})
        self.assertIn("$0.00", out)

    def test_malformed_input_prints_nothing_harmful(self):
        for raw in ("", "not json", "[]", "{}", '{"cost": 5}'):
            with self.subTest(raw=raw):
                out = self.run_script(None, raw=raw)
                self.assertNotIn("Traceback", out)
                self.assertLess(len(out), 200)

    def test_single_line_output(self):
        self.write_ledger([{"session_id": "o1", "ts_last": ts(), "cost_usd": 1}])
        self.assertEqual(self.run_script(self.payload()).count("\n"), 1)


if __name__ == "__main__":
    unittest.main()
