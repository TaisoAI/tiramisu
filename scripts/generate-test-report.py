#!/usr/bin/env python3
"""Generate a self-contained HTML test report from an xcresult bundle.

Sources of content:
  1. xcrun xcresulttool get test-results summary  → top-level counts
  2. xcrun xcresulttool get test-results tests    → suite/case tree
  3. xcrun xcresulttool get test-results activities --test-id ...
       → attached screenshots (UI tests use XCTAttachment)
  4. TiramisuTests/__Snapshots__/                 → snapshot golden PNGs
  5. TiramisuTests/*.swift, TiramisuUITests/*.swift
       → triple-slash doc-comments above each test, used as "what this verifies"

All images are inlined as base64 so the report is one self-contained file.
"""
from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from html import escape
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = ROOT / "TiramisuTests"
UITESTS_DIR = ROOT / "TiramisuUITests"
SNAPSHOTS_DIR = TESTS_DIR / "__Snapshots__"


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def xcresult_summary(bundle: Path) -> dict:
    return json.loads(run(["xcrun", "xcresulttool", "get", "test-results",
                           "summary", "--path", str(bundle)]))


def xcresult_tests(bundle: Path) -> dict:
    return json.loads(run(["xcrun", "xcresulttool", "get", "test-results",
                           "tests", "--path", str(bundle)]))


def xcresult_activities(bundle: Path, test_id: str) -> dict | None:
    """Returns activity tree for a test, or None if unavailable."""
    try:
        out = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "activities",
             "--path", str(bundle), "--test-id", test_id],
            check=True, capture_output=True, text=True).stdout
        return json.loads(out) if out.strip() else None
    except subprocess.CalledProcessError:
        return None


def export_attachment(bundle: Path, attachment_id: str, dest: Path) -> Path | None:
    """Try to export an attachment from the xcresult to disk."""
    try:
        subprocess.run(
            ["xcrun", "xcresulttool", "export", "object",
             "--path", str(bundle),
             "--id", attachment_id,
             "--output-path", str(dest),
             "--type", "file", "--legacy"],
            check=True, capture_output=True, text=True)
        return dest if dest.exists() else None
    except subprocess.CalledProcessError:
        return None


def collect_doc_comments() -> dict[str, dict]:
    """Scan test source files for `/// ...` doc-comments above each test
    function. Returns a map from test-case identifier (e.g.
    'ColorRGBTests/memberwiseInit()') and from `@Test("...")` displayName to
    the prose explanation."""
    docs: dict[str, dict] = {}
    files = list(TESTS_DIR.glob("*.swift")) + list(UITESTS_DIR.glob("*.swift"))

    re_test = re.compile(r'^\s*@Test\s*\(\s*"([^"]+)"', re.MULTILINE)
    re_func = re.compile(r'^\s*func\s+(\w+)\s*\(', re.MULTILINE)
    re_doc = re.compile(r'(?:^\s*///[^\n]*\n)+', re.MULTILINE)

    for f in files:
        text = f.read_text(encoding="utf-8")
        # Walk char-by-char isn't needed; use func declarations as anchors and
        # look back for adjacent @Test(...) and /// doc-block.
        for m in re.finditer(
                r'((?:^[ \t]*///[^\n]*\n)+)?'
                r'(?:^[ \t]*@Test\s*\(\s*"([^"]+)"[^\)]*\)\s*\n)?'
                r'^[ \t]*func\s+(\w+)\s*\(', text, re.MULTILINE):
            doc_block, display, fn_name = m.group(1), m.group(2), m.group(3)
            doc_text = ""
            if doc_block:
                doc_text = re.sub(r'^\s*///\s?', '', doc_block, flags=re.MULTILINE).strip()
            entry = {"file": f.name, "doc": doc_text, "display": display}
            # Index by func name + ()
            docs[f"{fn_name}()"] = entry
            if display:
                docs[display] = entry
    return docs


def b64_image(path: Path) -> str:
    if not path.exists():
        return ""
    data = path.read_bytes()
    mime = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(data).decode()}"


def collect_snapshot_goldens() -> list[dict]:
    """Return [{name, path, data_uri}] for every snapshot PNG on disk."""
    out = []
    if not SNAPSHOTS_DIR.exists():
        return out
    for png in sorted(SNAPSHOTS_DIR.rglob("*.png")):
        rel = png.relative_to(SNAPSHOTS_DIR)
        out.append({
            "name": str(rel),
            "test": rel.stem.split(".")[0],
            "data_uri": b64_image(png),
        })
    return out


def walk_tests(node: dict, suites: list[dict], current_suite: dict | None = None):
    """Flatten test tree into list of suites with cases."""
    nt = node.get("nodeType", "")
    if nt == "Test Suite":
        suite = {"name": node["name"], "result": node.get("result"), "cases": []}
        suites.append(suite)
        current_suite = suite
    elif nt == "Test Case":
        if current_suite is not None:
            current_suite["cases"].append({
                "name": node.get("name"),
                "result": node.get("result"),
                "duration": node.get("duration", ""),
                "duration_s": node.get("durationInSeconds", 0),
                "id": node.get("nodeIdentifier"),
                "id_url": node.get("nodeIdentifierURL"),
            })
    for child in node.get("children", []):
        walk_tests(child, suites, current_suite)


def collect_ui_screenshots(bundle: Path, suites: list[dict],
                           tmpdir: Path) -> dict[str, list[dict]]:
    """For UI tests (which call add(XCTAttachment(screenshot:))), try to
    extract attached screenshots. Returns map of test-id → [{name, data_uri}]."""
    out: dict[str, list[dict]] = {}
    for suite in suites:
        for case in suite["cases"]:
            test_id = case.get("id")
            if not test_id:
                continue
            # Only worth probing for UI tests — but cheap to probe all.
            activities = xcresult_activities(bundle, test_id)
            if not activities:
                continue
            shots = []
            stack = [activities]
            while stack:
                n = stack.pop()
                if not isinstance(n, dict):
                    continue
                # Newer xcresulttool returns "attachments" with payloadId/uuid
                for att in (n.get("attachments") or []):
                    aid = att.get("payloadId") or att.get("uuid") or att.get("id")
                    name = att.get("name") or att.get("filename") or "attachment"
                    if not aid:
                        continue
                    safe = re.sub(r'[^A-Za-z0-9_.-]', '_', f"{aid}_{name}")
                    dest = tmpdir / safe
                    if export_attachment(bundle, aid, dest):
                        if dest.suffix.lower() in (".png", ".jpg", ".jpeg", ".heic"):
                            shots.append({"name": name, "data_uri": b64_image(dest)})
                for k, v in n.items():
                    if isinstance(v, (dict, list)):
                        stack.extend(v if isinstance(v, list) else [v])
            if shots:
                out[test_id] = shots
    return out


def git_info() -> dict:
    def g(args: list[str]) -> str:
        try:
            return subprocess.run(["git"] + args, cwd=ROOT, check=True,
                                  capture_output=True, text=True).stdout.strip()
        except subprocess.CalledProcessError:
            return ""
    return {
        "sha": g(["rev-parse", "--short=10", "HEAD"]),
        "branch": g(["rev-parse", "--abbrev-ref", "HEAD"]),
        "subject": g(["log", "-1", "--pretty=%s"]),
        "dirty": bool(g(["status", "--porcelain"])),
    }


def render_html(summary: dict, suites: list[dict], docs: dict,
                snapshots: list[dict], ui_shots: dict[str, list[dict]],
                git: dict) -> str:
    passed = summary.get("passedTests", 0)
    failed = summary.get("failedTests", 0)
    skipped = summary.get("skippedTests", 0)
    result = summary.get("result", "Unknown")
    started = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(summary.get("startTime", time.time())))
    duration_s = (summary.get("finishTime", 0) - summary.get("startTime", 0))
    env = summary.get("environmentDescription", "")

    badge_color = {"Passed": "#0fae5e", "Failed": "#e23c3c"}.get(result, "#6b6b6b")
    dirty_badge = '<span class="badge dirty">dirty</span>' if git.get("dirty") else ""

    # Map snapshot goldens onto their owning test (filename stem == func name).
    case_snapshots: dict[str, list[dict]] = {}
    for s in snapshots:
        # `s["test"]` is e.g. "testGradientLayer" → owns case "testGradientLayer()"
        case_snapshots.setdefault(s["test"], []).append(s)

    def case_row(case: dict) -> str:
        case_name = case["name"]
        doc_entry = docs.get(case_name)
        prose = (doc_entry or {}).get("doc", "")
        file_hint = (doc_entry or {}).get("file", "")
        result_class = "ok" if case["result"] == "Passed" else (
            "skip" if case["result"] == "Skipped" else "fail")
        result_glyph = {"Passed": "✓", "Failed": "✗", "Skipped": "↷"}.get(case["result"], "?")

        # Collect images: snapshot goldens (matched by func-name stem) + UI screenshots.
        images: list[dict] = []
        func_match = re.match(r'^(\w+)\(\)$', case_name)
        if func_match:
            images.extend(case_snapshots.get(func_match.group(1), []))
        images.extend(ui_shots.get(case.get("id") or "", []))

        # Images use data-src so the browser only allocates them when expanded.
        shots_html = ""
        if images:
            shots_html = '<div class="shots">' + "".join(
                f'<figure><img class="shot" alt="{escape(img.get("name", ""))}" '
                f'data-src="{img["data_uri"]}">'
                f'<figcaption>{escape(img.get("name", ""))}</figcaption></figure>'
                for img in images
            ) + "</div>"

        n_imgs = len(images)
        # Picture-frame icon (mountain + sun) — universally recognized
        # as "image". Clicking the row expands to show the actual images.
        img_icon_svg = (
            '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" '
            'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">'
            '<rect x="3" y="3" width="18" height="18" rx="2.5"/>'
            '<circle cx="8.5" cy="9" r="1.5"/>'
            '<path d="M21 15l-5-5L5 21"/>'
            '</svg>'
        )
        img_badge = (
            f'<span class="img-badge" '
            f'title="Click to view {n_imgs} attached image{"s" if n_imgs != 1 else ""}">'
            f'{img_icon_svg}<span class="count">{n_imgs}</span></span>'
        ) if n_imgs else ''

        return f"""
        <details class="case {result_class}">
          <summary>
            <span class="glyph">{result_glyph}</span>
            <span class="case-title">{escape(case_name)}</span>
            {img_badge}
            <span class="dur">{escape(case.get("duration") or f"{case.get('duration_s', 0):.3f}s")}</span>
            <span class="chevron">›</span>
          </summary>
          <div class="case-body">
            {f'<div class="case-prose">{escape(prose)}</div>' if prose else ''}
            {f'<div class="case-file">{escape(file_hint)}</div>' if file_hint else ''}
            {shots_html}
          </div>
        </details>"""

    suites_html = ""
    for suite in suites:
        if not suite["cases"]:
            continue
        s_passed = sum(1 for c in suite["cases"] if c["result"] == "Passed")
        s_failed = sum(1 for c in suite["cases"] if c["result"] == "Failed")
        s_skipped = sum(1 for c in suite["cases"] if c["result"] == "Skipped")
        rows = "\n".join(case_row(c) for c in suite["cases"])
        suites_html += f"""
        <section class="suite" data-accordion>
          <header class="suite-h">
            <h2>{escape(suite['name'])}</h2>
            <span class="counts">
              <span class="ok">{s_passed} passed</span>
              {f'<span class="fail">{s_failed} failed</span>' if s_failed else ''}
              {f'<span class="skip">{s_skipped} skipped</span>' if s_skipped else ''}
            </span>
          </header>
          <div class="cases">{rows}</div>
        </section>"""

    # Snapshot gallery removed — goldens now live inside their owning test case.
    snapshot_html = ""

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Tiramisu — Test Report ({result})</title>
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
    --rad: 12px;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    font: 14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    background: var(--bg); color: var(--ink); margin: 0; padding: 32px;
  }}
  .wrap {{ max-width: 1100px; margin: 0 auto; }}
  h1 {{ font: 600 28px/1.2 "SF Pro Display", -apple-system, sans-serif; margin: 0 0 8px; color: var(--cocoa); }}
  h2 {{ font: 600 18px/1.3 "SF Pro Display", -apple-system, sans-serif; margin: 0; color: var(--cocoa); }}
  header.top {{
    background: var(--card); border: 1px solid var(--line);
    border-radius: var(--rad); padding: 24px 28px; margin-bottom: 24px;
    box-shadow: 0 1px 3px rgba(74,44,26,0.06);
    position: relative;
  }}
  .back-to-history {{
    display: inline-block;
    color: var(--muted); text-decoration: none;
    font-size: 12px; font-weight: 600;
    padding: 4px 10px; margin-bottom: 12px;
    border: 1px solid var(--line); border-radius: 999px;
    background: var(--bg);
    transition: color 0.12s ease, border-color 0.12s ease;
  }}
  .back-to-history:hover {{
    color: var(--cocoa); border-color: var(--cocoa);
  }}
  .meta {{ color: var(--muted); font-size: 13px; }}
  .meta code {{ background: var(--bg); padding: 2px 6px; border-radius: 4px; font-size: 12px; }}
  .badge {{
    display: inline-block; padding: 4px 10px; border-radius: 999px;
    font-weight: 600; font-size: 12px; letter-spacing: 0.04em;
    color: white; background: {badge_color}; text-transform: uppercase;
    vertical-align: middle; margin-left: 8px;
  }}
  .badge.dirty {{ background: var(--skip); }}
  .stats {{ display: flex; gap: 16px; margin-top: 16px; flex-wrap: wrap; }}
  .stat {{
    background: var(--bg); padding: 12px 18px; border-radius: 8px;
    border: 1px solid var(--line); flex: 1; min-width: 140px;
  }}
  .stat .num {{ font: 600 24px/1 "SF Pro Display", sans-serif; color: var(--cocoa); }}
  .stat .lbl {{ font-size: 12px; color: var(--muted); margin-top: 4px; text-transform: uppercase; letter-spacing: 0.05em; }}
  .stat.ok .num {{ color: var(--ok); }}
  .stat.fail .num {{ color: var(--fail); }}
  .stat.skip .num {{ color: var(--skip); }}

  section.suite {{
    background: var(--card); border: 1px solid var(--line);
    border-radius: var(--rad); margin-bottom: 20px; overflow: hidden;
    box-shadow: 0 1px 3px rgba(74,44,26,0.04);
  }}
  .suite-h {{
    display: flex; justify-content: space-between; align-items: center;
    padding: 16px 24px; border-bottom: 1px solid var(--line); background: #fffaf0;
  }}
  .counts {{ font-size: 13px; }}
  .counts span {{ margin-left: 12px; font-weight: 600; }}
  .counts .ok {{ color: var(--ok); }}
  .counts .fail {{ color: var(--fail); }}
  .counts .skip {{ color: var(--skip); }}
  .prose {{ padding: 12px 24px 0; color: var(--muted); margin: 0; }}

  .cases {{ padding: 0; }}
  details.case {{ border-bottom: 1px solid var(--line); }}
  details.case:last-child {{ border-bottom: 0; }}
  details.case > summary {{
    list-style: none;
    cursor: pointer;
    display: flex; align-items: center; gap: 12px;
    padding: 14px 24px;
    user-select: none;
  }}
  details.case > summary::-webkit-details-marker {{ display: none; }}
  details.case > summary:hover {{ background: #fffaf0; }}
  details.case[open] > summary {{ background: #fffaf0; border-bottom: 1px solid var(--line); }}
  details.case .glyph {{
    display: inline-flex; width: 22px; height: 22px; flex: 0 0 22px;
    align-items: center; justify-content: center; border-radius: 50%;
    font-weight: 700; font-size: 13px; color: white;
  }}
  details.case.ok .glyph {{ background: var(--ok); }}
  details.case.fail .glyph {{ background: var(--fail); }}
  details.case.skip .glyph {{ background: var(--skip); }}
  .case-title {{ font-weight: 600; color: var(--cocoa); flex: 1; }}
  .img-badge {{
    display: inline-flex; align-items: center; gap: 4px;
    font-size: 11px; font-weight: 600; color: var(--cocoa);
    background: linear-gradient(180deg, #fffaf0 0%, #f4ead0 100%);
    border: 1px solid #d6b97a;
    padding: 3px 8px 3px 6px; border-radius: 999px;
    box-shadow: 0 1px 0 rgba(74,44,26,0.04), inset 0 -1px 0 rgba(255,255,255,0.5);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    transition: transform 0.12s ease, box-shadow 0.12s ease;
  }}
  details.case > summary:hover .img-badge {{
    transform: translateY(-1px);
    box-shadow: 0 2px 4px rgba(74,44,26,0.12);
  }}
  .img-badge svg {{ width: 13px; height: 13px; flex: 0 0 13px; color: var(--cocoa); }}
  .img-badge .count {{ line-height: 1; }}
  .dur {{
    color: var(--muted); font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 12px; white-space: nowrap;
  }}
  .chevron {{
    color: var(--muted); font-size: 18px; line-height: 1;
    transition: transform 0.15s ease;
    transform: rotate(0deg);
    width: 14px; text-align: center;
  }}
  details.case[open] > summary .chevron {{ transform: rotate(90deg); }}

  .case-body {{ padding: 16px 24px 20px 58px; background: #fffefb; }}
  .case-prose {{ color: var(--ink); font-size: 14px; line-height: 1.55; max-width: 720px; }}
  .case-file {{
    color: #a3927d; font-size: 11px; margin-top: 8px;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
  }}

  .shots {{ display: flex; flex-wrap: wrap; gap: 16px; margin-top: 14px; }}
  .shots figure {{ margin: 0; }}
  .shots .shot {{
    display: block;
    max-width: 320px; max-height: 240px;
    border: 1px solid var(--line); border-radius: 8px; background: #f4ead0;
  }}
  .shots figcaption {{
    font: 11px ui-monospace, "SF Mono", Menlo, monospace;
    color: var(--muted); margin-top: 6px; text-align: center;
  }}

  footer {{ text-align: center; color: var(--muted); padding: 24px 0; font-size: 12px; }}
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <a class="back-to-history" href="index.html" title="Browse all archived runs">← All runs</a>
    <h1>Tiramisu test report <span class="badge">{escape(result)}</span> {dirty_badge}</h1>
    <div class="meta">
      {escape(env)} · ran {escape(started)} · {duration_s:.2f}s ·
      branch <code>{escape(git.get('branch') or '?')}</code> ·
      sha <code>{escape(git.get('sha') or '?')}</code>
      {f"· <em>{escape(git.get('subject') or '')}</em>" if git.get('subject') else ''}
    </div>
    <div class="stats">
      <div class="stat ok"><div class="num">{passed}</div><div class="lbl">Passed</div></div>
      <div class="stat fail"><div class="num">{failed}</div><div class="lbl">Failed</div></div>
      <div class="stat skip"><div class="num">{skipped}</div><div class="lbl">Skipped</div></div>
      <div class="stat"><div class="num">{len(suites)}</div><div class="lbl">Suites</div></div>
    </div>
  </header>

  {suites_html}
  {snapshot_html}

  <footer>
    Generated by <code>scripts/generate-test-report.sh</code> ·
    re-run via <code>scripts/ai-check.sh --open</code> ·
    click any test to expand · only one open at a time
  </footer>
</div>
<script>
  // Exclusive accordion within each suite + lazy-load images.
  // Images carry their data-URI in `data-src`; we copy it into `src` only
  // when the test is first opened. Closing it is a no-op (browser keeps
  // the cached image but at least no work happens for tests you never view).
  document.querySelectorAll('section.suite[data-accordion]').forEach(suite => {{
    const items = suite.querySelectorAll(':scope > .cases > details.case');
    items.forEach(d => {{
      d.addEventListener('toggle', () => {{
        if (d.open) {{
          // Lazy-load any images in this case body.
          d.querySelectorAll('img[data-src]').forEach(img => {{
            img.src = img.dataset.src;
            img.removeAttribute('data-src');
          }});
          // Close other open siblings in the same suite.
          items.forEach(other => {{
            if (other !== d && other.open) other.open = false;
          }});
        }}
      }});
    }});
  }});
</script>
</body>
</html>"""


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: generate-test-report.py <xcresult-bundle> <output-html>", file=sys.stderr)
        return 64

    bundle = Path(sys.argv[1]).resolve()
    out_html = Path(sys.argv[2]).resolve()
    out_html.parent.mkdir(parents=True, exist_ok=True)

    if not bundle.exists():
        print(f"error: xcresult bundle not found: {bundle}", file=sys.stderr)
        return 1

    summary = xcresult_summary(bundle)
    tests_root = xcresult_tests(bundle)
    docs = collect_doc_comments()
    snapshots = collect_snapshot_goldens()
    git = git_info()

    suites: list[dict] = []
    for top in tests_root.get("testNodes", []):
        walk_tests(top, suites)

    with tempfile.TemporaryDirectory(prefix="tiramisu-shots-") as tmp:
        ui_shots = collect_ui_screenshots(bundle, suites, Path(tmp))
        html = render_html(summary, suites, docs, snapshots, ui_shots, git)

    out_html.write_text(html, encoding="utf-8")
    print(f"Report: {out_html}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
