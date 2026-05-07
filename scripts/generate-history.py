#!/usr/bin/env python3
"""Generate `build/reports/index.html` — a dashboard listing every archived
test run with pass/fail counts and quick-open links.

Reads metadata from filenames (`<TS>-<SHA>-<passed|failed>.html`) and from
the embedded stat blocks in each report HTML, sorts newest-first, writes a
single self-contained index page that opens cleanly in a browser.

Run after `generate-test-report.py` has produced the per-run HTML.
"""
from __future__ import annotations

import re
import sys
from datetime import datetime
from html import escape
from pathlib import Path


FILENAME_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-(?P<sha>[0-9a-f]+)"
    r"-(?P<result>passed|failed)\.html$"
)

STAT_RE = re.compile(
    r'<div class="num">(\d+)</div>\s*<div class="lbl">([^<]+)</div>',
    re.IGNORECASE
)

DURATION_RE = re.compile(r"·\s*([\d.]+)s\s*·")


def parse_report(path: Path) -> dict | None:
    m = FILENAME_RE.match(path.name)
    if not m:
        return None
    text = path.read_text(encoding="utf-8", errors="ignore")
    stats: dict[str, int] = {}
    for num, lbl in STAT_RE.findall(text):
        stats[lbl.strip().lower()] = int(num)
    duration = None
    dm = DURATION_RE.search(text)
    if dm:
        try:
            duration = float(dm.group(1))
        except ValueError:
            pass
    return {
        "filename": path.name,
        "ts": datetime.strptime(m["ts"], "%Y-%m-%dT%H-%M-%S"),
        "sha": m["sha"],
        "result": m["result"],
        "passed": stats.get("passed", 0),
        "failed": stats.get("failed", 0),
        "skipped": stats.get("skipped", 0),
        "suites": stats.get("suites", 0),
        "duration": duration,
    }


def render(runs: list[dict]) -> str:
    if not runs:
        body_inner = '<p class="empty">No test reports yet. Run <code>./scripts/ai-check.sh</code> to record one.</p>'
        latest_summary = ""
    else:
        latest = runs[0]
        latest_summary = f"""
        <div class="latest">
          <div class="latest-label">Latest run</div>
          <div class="latest-meta">
            <span class="badge {latest['result']}">{escape(latest['result']).upper()}</span>
            <span>{latest['ts'].strftime('%Y-%m-%d %H:%M:%S')}</span>
            <span>·</span>
            <code>{escape(latest['sha'])}</code>
            <span>·</span>
            <span class="num ok">{latest['passed']}</span> passed
            {f"<span>·</span> <span class='num fail'>{latest['failed']}</span> failed" if latest['failed'] else ''}
            {f"<span>·</span> <span class='num skip'>{latest['skipped']}</span> skipped" if latest['skipped'] else ''}
          </div>
          <a class="open primary" href="{escape(latest['filename'])}">Open latest report →</a>
        </div>
        """

        rows = []
        for r in runs:
            cls = "ok" if r["result"] == "passed" else "fail"
            glyph = "✓" if r["result"] == "passed" else "✗"
            dur = f"{r['duration']:.1f}s" if r["duration"] is not None else "—"
            rows.append(
                f'<tr class="{cls}">'
                f'<td class="status"><span class="glyph">{glyph}</span></td>'
                f'<td class="when">{r["ts"].strftime("%Y-%m-%d %H:%M:%S")}</td>'
                f'<td class="sha"><code>{escape(r["sha"])}</code></td>'
                f'<td class="n ok">{r["passed"]}</td>'
                f'<td class="n fail">{r["failed"] if r["failed"] else "·"}</td>'
                f'<td class="n skip">{r["skipped"] if r["skipped"] else "·"}</td>'
                f'<td class="dur">{dur}</td>'
                f'<td class="open"><a href="{escape(r["filename"])}">open →</a></td>'
                f'</tr>'
            )
        rows_html = "\n".join(rows)
        body_inner = f"""
        <table>
          <thead>
            <tr>
              <th></th>
              <th>When</th>
              <th>Commit</th>
              <th class="ok">Passed</th>
              <th class="fail">Failed</th>
              <th class="skip">Skipped</th>
              <th>Duration</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows_html}
          </tbody>
        </table>
        """

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Tiramisu — Test History ({len(runs)} runs)</title>
<style>
  :root {{
    --bg: #fbf3e2;
    --card: #ffffff;
    --ink: #2a1d12;
    --muted: #6b5a47;
    --line: #ead9b8;
    --cocoa: #4a2c1a;
    --ok: #0fae5e;
    --fail: #e23c3c;
    --skip: #b78a3a;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    background: var(--bg); color: var(--ink); margin: 0; padding: 32px;
  }}
  .wrap {{ max-width: 1100px; margin: 0 auto; }}
  h1 {{ font: 600 28px/1.2 "SF Pro Display", -apple-system, sans-serif; margin: 0 0 8px; color: var(--cocoa); }}
  .sub {{ color: var(--muted); font-size: 13px; margin-bottom: 24px; }}

  .latest {{
    background: var(--card); border: 1px solid var(--line);
    border-radius: 12px; padding: 20px 24px; margin-bottom: 24px;
    box-shadow: 0 1px 3px rgba(74,44,26,0.06);
    display: flex; align-items: center; gap: 16px; flex-wrap: wrap;
  }}
  .latest-label {{ font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; flex: 0 0 auto; }}
  .latest-meta {{ display: flex; align-items: center; gap: 8px; font-size: 14px; flex: 1 1 auto; flex-wrap: wrap; }}
  .latest-meta code {{ background: var(--bg); padding: 2px 6px; border-radius: 4px; font-size: 12px; }}

  .badge {{
    display: inline-block; padding: 3px 10px; border-radius: 999px;
    font-weight: 700; font-size: 11px; letter-spacing: 0.05em;
    color: white; text-transform: uppercase;
  }}
  .badge.passed {{ background: var(--ok); }}
  .badge.failed {{ background: var(--fail); }}

  .open.primary {{
    display: inline-block;
    background: var(--cocoa); color: white;
    padding: 8px 14px; border-radius: 8px;
    text-decoration: none; font-weight: 600;
    box-shadow: 0 1px 3px rgba(74,44,26,0.2);
    transition: transform 0.12s ease, box-shadow 0.12s ease;
    flex: 0 0 auto;
  }}
  .open.primary:hover {{ transform: translateY(-1px); box-shadow: 0 3px 6px rgba(74,44,26,0.25); }}

  table {{
    width: 100%; border-collapse: collapse;
    background: var(--card); border: 1px solid var(--line);
    border-radius: 12px; overflow: hidden;
    box-shadow: 0 1px 3px rgba(74,44,26,0.04);
  }}
  thead {{ background: #fffaf0; }}
  th {{
    text-align: left; padding: 12px 16px; font-size: 11px;
    color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em;
    font-weight: 600; border-bottom: 1px solid var(--line);
  }}
  th.ok {{ color: var(--ok); }}
  th.fail {{ color: var(--fail); }}
  th.skip {{ color: var(--skip); }}
  td {{ padding: 12px 16px; border-bottom: 1px solid var(--line); }}
  tr:last-child td {{ border-bottom: 0; }}
  tr:hover td {{ background: #fffaf0; }}
  tr.fail td.when, tr.fail td.sha {{ color: var(--fail); font-weight: 600; }}

  td.status {{ width: 36px; }}
  td.status .glyph {{
    display: inline-flex; width: 22px; height: 22px;
    align-items: center; justify-content: center; border-radius: 50%;
    font-weight: 700; font-size: 13px; color: white;
  }}
  tr.ok .glyph {{ background: var(--ok); }}
  tr.fail .glyph {{ background: var(--fail); }}

  td.sha code {{
    background: var(--bg); padding: 2px 6px; border-radius: 4px;
    font: 12px ui-monospace, "SF Mono", Menlo, monospace;
  }}
  td.when {{ font: 13px ui-monospace, "SF Mono", Menlo, monospace; color: var(--ink); }}
  td.n {{ font: 600 13px ui-monospace, "SF Mono", Menlo, monospace; text-align: right; min-width: 60px; }}
  td.n.ok {{ color: var(--ok); }}
  td.n.fail {{ color: var(--fail); }}
  td.n.skip {{ color: var(--skip); }}
  td.dur {{ font: 12px ui-monospace, "SF Mono", Menlo, monospace; color: var(--muted); }}
  td.open a {{
    color: var(--cocoa); text-decoration: none; font-weight: 600;
    font-size: 13px; padding: 4px 8px; border-radius: 6px;
  }}
  td.open a:hover {{ background: var(--bg); }}

  .empty {{
    background: var(--card); border: 1px solid var(--line);
    border-radius: 12px; padding: 32px; text-align: center;
    color: var(--muted);
  }}
  .empty code {{ background: var(--bg); padding: 2px 8px; border-radius: 4px; }}

  footer {{ text-align: center; color: var(--muted); padding: 24px 0; font-size: 12px; }}
</style>
</head>
<body>
<div class="wrap">
  <h1>Tiramisu test history</h1>
  <div class="sub">{len(runs)} archived run{'' if len(runs) == 1 else 's'} · regenerated each time <code>./scripts/ai-check.sh</code> runs</div>

  {latest_summary}
  {body_inner}

  <footer>
    Click any row to open its full report. Files live under <code>build/reports/</code>.<br>
    Wipe history with <code>rm -rf build/reports build/results</code>.
  </footer>
</div>
</body>
</html>"""


def main(argv: list[str]) -> int:
    if len(argv) >= 2:
        reports_dir = Path(argv[1]).resolve()
    else:
        reports_dir = Path(__file__).resolve().parent.parent / "build" / "reports"

    if not reports_dir.exists():
        print(f"no reports dir at {reports_dir}", file=sys.stderr)
        return 1

    runs: list[dict] = []
    for f in sorted(reports_dir.glob("*.html")):
        if f.name == "index.html":
            continue
        info = parse_report(f)
        if info:
            runs.append(info)

    runs.sort(key=lambda r: r["ts"], reverse=True)

    out = reports_dir / "index.html"
    out.write_text(render(runs), encoding="utf-8")
    print(f"History dashboard: {out}  ({len(runs)} runs)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
