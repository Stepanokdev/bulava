#!/usr/bin/env python3
"""Build a throwaway Bulava state directory that the website can be photographed against.

The screenshots on bulava.app have to show the real application, and the real application on this
machine is full of somebody's clients. Rather than blur them afterwards — which is a promise that
the blur was thorough — this builds a second, isolated Bulava: its own product registry, its own
engine state, its own projects under a temporary directory, and English as the interface language.
Nothing it writes can reach the director's own state, because `BULAVA_STATE_DIR` and
`SUPERVISOR_STATE_DIR` redirect every store the app has.

The products in here are invented. `check-screenshots.py` asserts that afterwards, against the
folders this machine has actually worked in, so an invented name cannot quietly become a real one.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone

from words import LANG, w

ROOT = os.path.dirname(os.path.abspath(__file__))


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def slug_for_path(path):
    """The engine's instance slug: sanitized folder name + 12 hex of the SHA-1 of the path."""
    name = "".join(c if (c.isalnum() and c.isascii()) or c == "-" else "-"
                   for c in os.path.basename(path))
    digest = hashlib.sha1(path.encode()).hexdigest()[:12]
    return f"{name}-{digest}"


def transcript_dir_name(path):
    """Claude Code's own naming for a project's session folder."""
    return "".join(c if (c.isalpha() and c.isascii()) or c.isdigit() or c == "-" else "-"
                   for c in path)


# ── the cast ────────────────────────────────────────────────────────────────────────────────────
# Three products, because one is a screenshot of an empty app and five is a screenshot of somebody
# else's mess. Bulava is in the list on purpose: it is the product that built itself, and leaving
# it out of its own sidebar would be a staged photograph.

P_LEDGER = "a1b1c1d1-0001-4000-8000-000000000001"
P_BULAVA = "a1b1c1d1-0002-4000-8000-000000000002"
P_TRAIL  = "a1b1c1d1-0003-4000-8000-000000000003"

R_LEDGER_MAC = "b1b1c1d1-0001-4000-8000-000000000001"
R_LEDGER_API = "b1b1c1d1-0002-4000-8000-000000000002"
R_BULAVA_APP = "b1b1c1d1-0003-4000-8000-000000000003"
R_TRAIL_IOS  = "b1b1c1d1-0004-4000-8000-000000000004"

J_LEDGER_MAC = "c1b1c1d1-0001-4000-8000-000000000001"
J_LEDGER_API = "c1b1c1d1-0002-4000-8000-000000000002"
J_BULAVA_APP = "c1b1c1d1-0003-4000-8000-000000000003"
J_TRAIL_IOS  = "c1b1c1d1-0004-4000-8000-000000000004"

CHAT_EXPORT = "d1b1c1d1-0001-4000-8000-000000000001"
CHAT_SYNC   = "d1b1c1d1-0002-4000-8000-000000000002"
CHAT_BULAVA = "d1b1c1d1-0003-4000-8000-000000000003"

TASK_EXPORT = "e1b1c1d1-0001-4000-8000-000000000001"
TASK_SYNC   = "e1b1c1d1-0002-4000-8000-000000000002"

SESSION_EXPORT = "f1b1c1d1-0001-4000-8000-000000000001"
RUN_EXPORT = "RUN-0001-DEMO"


def build(root):
    state = os.path.join(root, "state")
    supervisor = os.path.join(root, "supervisor")
    work = os.path.join(root, "work")
    for d in (state, supervisor, work):
        os.makedirs(d, exist_ok=True)

    projects = {
        J_LEDGER_MAC: (os.path.join(work, "pocket-ledger-mac"), "pocket-ledger-mac"),
        J_LEDGER_API: (os.path.join(work, "pocket-ledger-api"), "pocket-ledger-api"),
        J_BULAVA_APP: (os.path.join(work, "bulava"), "bulava"),
        J_TRAIL_IOS:  (os.path.join(work, "trailmark-ios"), "trailmark-ios"),
    }
    for path, _ in projects.values():
        os.makedirs(path, exist_ok=True)

    now = datetime.now(timezone.utc)
    t = lambda mins: iso(now - timedelta(minutes=mins))

    # ── products ────────────────────────────────────────────────────────────────────────────────
    products = [
        {
            "id": P_LEDGER, "name": "Pocket Ledger",
            "summary": "", "pinned": True,
            "addedAt": t(60 * 24 * 40), "lastOpenedAt": t(2), "lastWorkedAt": t(2),
            "brief": w("ledger.brief"),
            "decisions": [], "iconScanned": True,
            "resources": [
                {"id": R_LEDGER_MAC, "name": "pocket-ledger-mac", "kind": "repository",
                 "access": "workspace", "projectID": J_LEDGER_MAC, "note": ""},
                {"id": R_LEDGER_API, "name": "pocket-ledger-api", "kind": "repository",
                 "access": "workspace", "projectID": J_LEDGER_API, "note": ""},
            ],
        },
        {
            "id": P_BULAVA, "name": "Bulava",
            "summary": "", "pinned": True,
            "addedAt": t(60 * 24 * 90), "lastOpenedAt": t(180), "lastWorkedAt": t(180),
            "brief": w("bulava.brief"),
            "decisions": [], "iconScanned": True,
            "resources": [
                {"id": R_BULAVA_APP, "name": "bulava", "kind": "repository",
                 "access": "workspace", "projectID": J_BULAVA_APP, "note": ""},
            ],
        },
        {
            "id": P_TRAIL, "name": "Trailmark",
            "summary": "", "pinned": False,
            "addedAt": t(60 * 24 * 12), "lastOpenedAt": t(60 * 30), "lastWorkedAt": t(60 * 30),
            "brief": w("trail.brief"),
            "decisions": [], "iconScanned": True,
            "resources": [
                {"id": R_TRAIL_IOS, "name": "trailmark-ios", "kind": "repository",
                 "access": "workspace", "projectID": J_TRAIL_IOS, "note": ""},
            ],
        },
    ]
    write(state, "products.json", products)

    write(state, "projects.json", [
        {"id": jid, "name": name, "path": path, "kind": "unknown", "stacks": [],
         "pinned": False, "addedAt": t(60 * 24 * 40), "notes": ""}
        for jid, (path, name) in projects.items()
    ])

    # ── the thread the screenshots are taken of ─────────────────────────────────────────────────
    ledger_mac = projects[J_LEDGER_MAC][0]
    chats = [
        {"id": CHAT_EXPORT, "productID": P_LEDGER,
         "title": w("task.export"),
         "createdAt": t(54), "updatedAt": t(2), "archived": False, "pinned": False,
         "firstMessage": w("msg.first"),
         "session": {"primaryProjectID": J_LEDGER_MAC, "projectPath": ledger_mac,
                     "claudeSessionID": SESSION_EXPORT, "activeRunID": RUN_EXPORT,
                     "startedAt": t(54), "reportPaths": []}},
        {"id": CHAT_SYNC, "productID": P_LEDGER,
         "title": w("task.sync"),
         "createdAt": t(60 * 26), "updatedAt": t(60 * 22), "archived": False, "pinned": False,
         "firstMessage": w("chat.sync.first"),
         "session": {"primaryProjectID": J_LEDGER_API, "projectPath": projects[J_LEDGER_API][0],
                     "startedAt": t(60 * 26), "reportPaths": []}},
        {"id": CHAT_BULAVA, "productID": P_BULAVA,
         "title": w("task.shortcuts"),
         "createdAt": t(60 * 50), "updatedAt": t(60 * 49), "archived": False, "pinned": False,
         "firstMessage": w("chat.shortcuts.first"),
         "session": {"primaryProjectID": J_BULAVA_APP, "projectPath": projects[J_BULAVA_APP][0],
                     "startedAt": t(60 * 50), "reportPaths": []}},
    ]
    write(state, "chats.json", chats)

    # ── the task card that sits in the thread ───────────────────────────────────────────────────
    write(state, "backlog.json", [
        {"id": TASK_EXPORT, "title": w("task.export"),
         "detail": "", "projectID": J_LEDGER_MAC, "projectPath": ledger_mac,
         "productID": P_LEDGER, "chatID": CHAT_EXPORT,
         "type": "feature", "priority": 2, "state": "in_progress",
         "createdAt": t(54), "updatedAt": t(2), "dispatchedAt": t(52),
         "boundSessionID": SESSION_EXPORT, "boundRunID": RUN_EXPORT,
         "boundBranch": "night/2026-09-20", "boundBaseBranch": "main",
         "wantsReport": True, "autoResume": True,
         "reviewFeedback": [], "dependsOn": [], "attachments": [],
         "writePaths": [], "nonGoals": [], "acceptance": [w("ac.1"), w("ac.2"), w("ac.3")],
         "surfaceUserFacingCopy": False, "surfaceVisual": True, "surfaceBehavior": True,
         "planSteps": []},
        {"id": TASK_SYNC, "title": w("task.sync"),
         "detail": "", "projectID": J_LEDGER_API, "projectPath": projects[J_LEDGER_API][0],
         "productID": P_LEDGER, "chatID": CHAT_SYNC,
         "type": "feature", "priority": 2, "state": "done",
         "createdAt": t(60 * 26), "updatedAt": t(60 * 22), "dispatchedAt": t(60 * 26),
         "lastOutcome": "succeeded_changes",
         "wantsReport": True, "autoResume": True,
         "reviewFeedback": [], "dependsOn": [], "attachments": [],
         "writePaths": [], "nonGoals": [], "acceptance": [],
         "surfaceUserFacingCopy": False, "surfaceVisual": False, "surfaceBehavior": True,
         "planSteps": []},
    ])

    write(state, "conversations.json", [
        {"id": "aa000000-0000-4000-8000-000000000001", "productID": P_LEDGER,
         "chatID": CHAT_EXPORT, "kind": "task", "at": t(54),
         "text": w("task.export"), "blocks": [], "tone": "neutral",
         "taskID": TASK_EXPORT, "attachments": []},
    ])

    # ── the worker's own transcript, where Claude Code keeps it ─────────────────────────────────
    home = os.path.expanduser("~")
    session_dir = os.path.join(home, ".claude", "projects", transcript_dir_name(ledger_mac))
    os.makedirs(session_dir, exist_ok=True)
    with open(os.path.join(session_dir, SESSION_EXPORT + ".jsonl"), "w") as f:
        f.write(transcript(now))

    # ── engine state: one live run, and the limits block with something in it ───────────────────
    inst = os.path.join(supervisor, "instances", slug_for_path(ledger_mac))
    os.makedirs(inst, exist_ok=True)
    put(inst, "project", ledger_mac)
    put(inst, "run-id", RUN_EXPORT)
    run = os.path.join(supervisor, "runs", RUN_EXPORT)
    os.makedirs(run, exist_ok=True)
    put(run, "project", ledger_mac)

    # ── a real repository, a real branch, a real diff ───────────────────────────────────────────
    # The review panel is not a rendering of stored text: it shells out to git in the project and
    # shows what actually changed. A fixture that only wrote JSON would photograph an empty review
    # and the page would be making a claim its own picture disproves.
    base_sha = build_repo(ledger_mac)

    # Written now rather than guessed earlier: the review refuses evidence whose base does not
    # match the branch it is looking at, which is the point of binding it at all.
    backlog_path = os.path.join(state, "backlog.json")
    backlog = json.load(open(backlog_path, encoding="utf-8"))
    backlog[0]["boundBaseSHA"] = base_sha
    write(state, "backlog.json", backlog)

    # And the verifier's evidence for that run, where the app binds it: by session inside the run.
    ev_dir = os.path.join(run, "evidence", SESSION_EXPORT)
    os.makedirs(ev_dir, exist_ok=True)
    write(ev_dir, "evidence.json", {
        "project_dir": ledger_mac,
        "session_id": SESSION_EXPORT,
        "base_sha": base_sha,
        "work_tree_digest": "b7d1c4e9f2a08c15",
        "stacks": ["swift"],
        "overall_status": "pass",
        "criteria": [
            {"criterion": w("ac.1"), "command": "swift test --filter CSVExportTests",
             "exit_code": 0, "artifact": "tests/csv-export.log",
             "status": "pass", "note": w("ev.1")},
            {"criterion": w("ac.2"), "command": "swift test --filter AmountFormatting",
             "exit_code": 0, "artifact": "tests/amount-formatting.log",
             "status": "pass", "note": w("ev.2")},
            {"criterion": w("ac.3"), "command": "swift test --filter SavePanelCancelled",
             "exit_code": 0, "artifact": "tests/save-panel.log",
             "status": "pass", "note": w("ev.3")},
            {"criterion": w("ac.4"), "command": "swift test",
             "exit_code": 0, "artifact": "tests/full-suite.log",
             "status": "pass", "note": w("ev.4")},
        ],
    })

    # The shape the engine's own statusline writes, not an invented one: the app decodes exactly
    # these keys, and a near-miss shows as a dash where a number belongs.
    stamp = now.timestamp()
    write(supervisor, "usage.json", {
        "ts": stamp,
        "plan": "Max",
        "five_hour": {"used_percentage": 38, "resets_at": stamp + 2 * 3600 + 600},
        "seven_day": {"used_percentage": 54, "resets_at": stamp + 3 * 86400},
    })
    # Written so the sidebar has something to draw the moment the window opens; the app replaces
    # both of these with the machine's real figures on its first poll. See write_settings.
    write(supervisor, "codex-usage.json", {
        "ts": stamp,
        "five_hour": {"used_percentage": 22, "resets_at": stamp + 3 * 3600},
        "seven_day": {"used_percentage": 41, "resets_at": stamp + 4 * 86400},
    })

    # A watchdog the app can see, so the sidebar reads "working" rather than "idle".
    #
    # This is a fixture, and it is worth saying plainly what it does and does not mean: the
    # interface below is exactly what a director sees while a run is going, and nothing behind it
    # is doing any work. The app decides "running" by asking whether the watchdog for this
    # instance is alive — `ps` must show a process whose command names watchdog.sh and the slug —
    # so the fixture provides one that does nothing but stay alive.
    watchdog = os.path.join(root_of(supervisor), "bin")
    os.makedirs(watchdog, exist_ok=True)
    script = os.path.join(watchdog, "watchdog.sh")
    put_exec(script, "#!/bin/bash\n# A stand-in for the real watchdog, alive so the interface can\n"
                     "# be photographed in the state it is in while work runs.\nsleep 900\n")
    proc = subprocess.Popen([script, slug_for_path(ledger_mac)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    put(inst, "watchdog.pid", str(proc.pid))
    put(inst, "session", "night-" + slug_for_path(ledger_mac))
    put(inst, "last-activity", iso(now))
    put(inst, "started-at", str((now - timedelta(minutes=52)).timestamp()))

    write_settings(state, supervisor, os.path.join(root_of(supervisor), "no-engine"))

    return state, supervisor


def write_settings(state, supervisor, orchestrator_home):
    """The demo instance's own settings, in the defaults suite the app derives from its state dir.

    Pins the things a photograph must not be left to inherit: English, the light appearance, the
    poll interval, and an orchestrator home with no `bin` in it so the demo cannot drive anything.

    What it does NOT pin, and cannot: the usage meters in the sidebar. The app refreshes those
    from the real Claude and Codex accounts on this machine and overwrites whatever the fixture
    wrote within seconds — tried, measured, and the numbers came back real. Which is the right
    behaviour, so the frames are simply taken when those numbers read the way an ordinary working
    day reads. On the evening this was first run, Codex was at 100% and had to be waited out.
    """
    import base64
    import hashlib
    import subprocess as sp

    digest = hashlib.sha256(state.encode()).hexdigest()[:16]
    suite = "com.nightshift.settings.fixture." + digest
    settings = {
        "stateDirPath": supervisor,
        "orchestratorHomePath": orchestrator_home,
        "pollSeconds": 4,
        "appearance": "dark",
        "interfaceLanguage": LANG,
        "reportLanguage": LANG,
        "askUserEnabled": True,
        "askUserWaitMinutes": 60,
        "chatMode": "peer",
        "limitsCollapsed": True,
    }
    blob = json.dumps(settings).encode()
    sp.run(["defaults", "write", suite, "com.nightshift.settings.v1",
            "-data", blob.hex()], check=True, capture_output=True)
    return suite


def root_of(supervisor):
    return os.path.dirname(supervisor)


def put_exec(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, 0o755)


def transcript(now):
    """A real turn, in Claude Code's own NDJSON: the prompt, the work, and what it said at the end."""
    at = lambda mins: iso(now - timedelta(minutes=mins))
    lines = []

    def user_prompt(text, mins, uuid):
        lines.append(json.dumps({
            "type": "user", "uuid": uuid, "sessionId": SESSION_EXPORT,
            "timestamp": at(mins), "promptSource": "typed",
            "message": {"role": "user", "content": [{"type": "text", "text": text}]},
        }))

    def says(text, mins, mid):
        lines.append(json.dumps({
            "type": "assistant", "timestamp": at(mins), "sessionId": SESSION_EXPORT,
            "message": {"id": mid, "content": [{"type": "text", "text": text}]},
        }))

    def tool(name, inp, mins, tid, result="", is_error=False):
        lines.append(json.dumps({
            "type": "assistant", "timestamp": at(mins), "sessionId": SESSION_EXPORT,
            "message": {"id": "msg-" + tid,
                        "content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]},
        }))
        lines.append(json.dumps({
            "type": "user", "timestamp": at(mins), "sessionId": SESSION_EXPORT,
            "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tid, "is_error": is_error,
                 "content": result}]},
        }))

    def finished(mins):
        lines.append(json.dumps({
            "type": "result", "subtype": "success", "is_error": False,
            "session_id": SESSION_EXPORT, "timestamp": at(mins),
        }))

    user_prompt(w("msg.first"), 54, "11110000-0000-4000-8000-000000000001")
    says(w("say.open"), 53, "m-open")
    tool("Read", {"file_path": "Sources/PocketLedger/TransactionsList.swift"}, 52, "toolu_01",
         "  1\timport SwiftUI\n  2\t\n  3\tstruct TransactionsList: View {")
    tool("Grep", {"pattern": "dateRange|activeFilter", "path": "Sources"}, 51, "toolu_02",
         "Sources/PocketLedger/TransactionFilter.swift:14:    var dateRange: ClosedRange<Date>")
    tool("Read", {"file_path": "Sources/PocketLedger/TransactionFilter.swift"}, 50, "toolu_03",
         "  1\timport Foundation")
    says(w("say.plan"), 48, "m-plan")
    tool("Write", {"file_path": "Sources/PocketLedger/CSVExport.swift"}, 46, "toolu_04", "ok")
    tool("Edit", {"file_path": "Sources/PocketLedger/TransactionsList.swift"}, 44, "toolu_05", "ok")
    tool("Write", {"file_path": "Tests/PocketLedgerTests/CSVExportTests.swift"}, 41, "toolu_06", "ok")
    tool("Bash", {"command": "swift test --filter CSVExportTests",
                  "description": "Run the export tests"}, 38, "toolu_07",
         "Test Suite 'CSVExportTests' passed at 2026-09-20\n\t Executed 7 tests, with 0 failures")
    says(w("say.tests"), 36, "m-tests")
    tool("consult-codex", {"question": w("consult.ask")}, 34, "toolu_08", w("consult.answer"))
    says(w("say.took"), 32, "m-took")
    tool("Edit", {"file_path": "Sources/PocketLedger/CSVExport.swift"}, 30, "toolu_09", "ok")
    tool("Bash", {"command": "swift test", "description": "Run the whole suite"}, 26, "toolu_10",
         "Executed 214 tests, with 0 failures")
    finished(24)

    user_prompt(w("ask.columns"), 22, "11110000-0000-4000-8000-000000000002")
    says(w("say.answer"), 21, "m-answer")
    tool("Bash", {"command": "swift test --filter ColumnOrder",
                  "description": "Check the column-order test"}, 20, "toolu_11",
         "Executed 2 tests, with 0 failures")
    finished(19)
    return "\n".join(lines) + "\n"


def build_repo(path):
    """A repository with a branch to review, and the base commit its diff is measured from.

    Committed with an explicit identity so the frames never carry whoever is running this.
    """
    env = dict(os.environ,
               GIT_AUTHOR_NAME="Pocket Ledger", GIT_AUTHOR_EMAIL="dev@example.com",
               GIT_COMMITTER_NAME="Pocket Ledger", GIT_COMMITTER_EMAIL="dev@example.com",
               GIT_CONFIG_GLOBAL=os.path.join(path, ".gitconfig-none"),
               GIT_CONFIG_SYSTEM=os.path.join(path, ".gitconfig-none"))

    def git(*args):
        return subprocess.run(["git"] + list(args), cwd=path, env=env,
                              capture_output=True, text=True).stdout.strip()

    sources = os.path.join(path, "Sources", "PocketLedger")
    tests = os.path.join(path, "Tests", "PocketLedgerTests")
    for d in (sources, tests):
        os.makedirs(d, exist_ok=True)

    put(path, "README.md", "# Pocket Ledger\n\nShared household spending, on a Mac and a phone.")
    put(sources, "TransactionsList.swift", BEFORE_LIST)
    put(sources, "TransactionFilter.swift",
        "import Foundation\n\nstruct TransactionFilter {\n    var dateRange: ClosedRange<Date>\n}")
    git("init", "-q", "-b", "main")
    git("add", "-A")
    git("commit", "-q", "-m", "The transactions list, filtered by date")
    base = git("rev-parse", "HEAD")

    git("checkout", "-q", "-b", "night/2026-09-20")
    put(sources, "CSVExport.swift", CSV_EXPORT)
    put(sources, "TransactionsList.swift", AFTER_LIST)
    put(tests, "CSVExportTests.swift", CSV_TESTS)
    git("add", "-A")
    git("commit", "-q", "-m", "Export the visible transactions to CSV")
    put(sources, "CSVExport.swift", CSV_EXPORT.replace(
        "formatter.locale = Locale.current",
        'formatter.locale = Locale(identifier: "en_US_POSIX")'))
    git("add", "-A")
    git("commit", "-q", "-m", "Write the file in a fixed locale, and open it after the panel answers")
    return base


BEFORE_LIST = """import SwiftUI

struct TransactionsList: View {
    @Environment(Ledger.self) private var ledger
    @Binding var filter: TransactionFilter

    var body: some View {
        Table(ledger.transactions(in: filter.dateRange)) {
            TableColumn("Date", value: \\.dayLabel)
            TableColumn("Who", value: \\.payer)
            TableColumn("Note", value: \\.note)
            TableColumn("Amount", value: \\.formattedAmount)
        }
    }
}
"""

AFTER_LIST = """import SwiftUI

struct TransactionsList: View {
    @Environment(Ledger.self) private var ledger
    @Binding var filter: TransactionFilter
    @State private var exporting = false

    var body: some View {
        Table(ledger.transactions(in: filter.dateRange)) {
            TableColumn("Date", value: \\.dayLabel)
            TableColumn("Who", value: \\.payer)
            TableColumn("Note", value: \\.note)
            TableColumn("Amount", value: \\.formattedAmount)
        }
        .toolbar {
            Button("Export…") { exporting = true }
                .help("Save what the filter is showing as a CSV file")
        }
        .fileExporter(isPresented: $exporting,
                      document: CSVExport(rows: ledger.transactions(in: filter.dateRange),
                                          columns: visibleColumns),
                      contentType: .commaSeparatedText,
                      defaultFilename: "transactions") { _ in }
    }
}
"""

CSV_EXPORT = """import Foundation
import UniformTypeIdentifiers

/// The visible transactions, as a file a spreadsheet will read back unchanged.
///
/// Quoting follows RFC 4180: a field containing a comma, a quote or a newline is wrapped in
/// quotes and its own quotes are doubled. A note is free text, so this is the normal case and
/// not the edge one.
struct CSVExport: FileDocument {
    static let readableContentTypes = [UTType.commaSeparatedText]

    let rows: [Transaction]
    let columns: [Column]

    private var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale.current
        return formatter
    }

    private func escape(_ field: String) -> String {
        guard field.contains(where: { ",\"\n\r".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
"""

CSV_TESTS = """import XCTest
@testable import PocketLedger

final class CSVExportTests: XCTestCase {

    func testANoteWithACommaSurvivesTheRoundTrip() throws {
        let row = Transaction(note: "milk, bread and a newspaper", amount: 12.4)
        XCTAssertEqual(try line(for: row), "\"milk, bread and a newspaper\",12.40")
    }

    func testAQuoteInsideANoteIsDoubled() throws {
        let row = Transaction(note: "the \"good\" coffee", amount: 4)
        XCTAssertEqual(try line(for: row), "\"the \"\"good\"\" coffee\",4.00")
    }
}
"""


def write(d, name, obj):
    with open(os.path.join(d, name), "w") as f:
        json.dump(obj, f, indent=2)


def put(d, name, text):
    with open(os.path.join(d, name), "w") as f:
        f.write(text + "\n")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.environ.get("TMPDIR", "/tmp"), "bulava-demo")
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    state, supervisor = build(root)
    print(state)
    print(supervisor)


if __name__ == "__main__":
    main()
