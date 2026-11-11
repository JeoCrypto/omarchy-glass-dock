// Runs BoundedRun through the cases that matter and prints one line per case:
//   CASE <name> PASS|FAIL <details>
// Started by tests/test_bounded_run.py with BoundedRun.qml copied next to it
// and stand-ins for pgrep and pkill in blind/.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root

  property int index: -1
  property int reports: 0
  property var began: 0
  property var cases: [
    { name: "success", argv: ["printf", "hello"],
      check: (c, o, e) => c === 0 && o === "hello" },
    { name: "exit-code-and-errors", argv: ["sh", "-c", "echo oops >&2; exit 3"],
      check: (c, o, e) => c === 3 && e.trim() === "oops" },
    { name: "output-cap", argv: ["yes"], seconds: 2, maxBytes: 1000,
      check: (c, o, e) => o.length === 1000 },
    { name: "input", argv: ["head", "-n1"], input: "from stdin\n",
      check: (c, o, e) => c === 0 && o.trim() === "from stdin" },
    { name: "time-limit", argv: ["sleep", "30"], seconds: 1,
      check: (c, o, e, ms) => c === 124 && ms < 4000 },
    // The helper cannot be started at all: still exactly one report.
    { name: "failed-start", argv: ["true"], launcher: ["/nonexistent/bounded-run-test"],
      check: (c, o, e) => c === 127 && e !== "" },
    { name: "runs-again-after-failed-start", argv: ["printf", "again"],
      check: (c, o, e) => c === 0 && o === "again" },
    // A child that leaves the command's process group and keeps the output
    // open: `timeout` cannot end this run, so the deadline has to, and the
    // child must be gone afterwards.
    { name: "deadline-stops-stragglers", seconds: 1, graceSeconds: 1,
      argv: ["bash", "-c", "set -m; sleep 31.4159 & disown; echo started"],
      check: (c, o, e, ms) => c !== 0 && ms < 6000, gone: "sleep 31.4159" },
    // A child left behind by a run that ended normally is stopped as well.
    { name: "normal-end-leaves-nothing",
      argv: ["bash", "-c", "set -m; sleep 32.7182 >/dev/null 2>&1 & disown; echo done"],
      check: (c, o, e) => c === 0 && o.trim() === "done", gone: "sleep 32.7182" },
    { name: "cancel", argv: ["sleep", "30"], seconds: 20, cancelAfter: 300,
      check: (c, o, e, ms) => c !== 0 && ms < 4000 },
    // A supervisor that cannot be asked to stop is stopped from outside,
    // together with what it started.
    { name: "stops-a-stuck-supervisor", argv: ["sleep", "33.3333"], seconds: 20, cancelAfter: 300,
      launcher: ["setsid", "env", "--ignore-signal=TERM", "bash"],
      check: (c, o, e, ms) => c !== 0 && ms < 6000, gone: "sleep 33.3333" },
    // The supervisor's own cleanup fails after the command has ended and been
    // collected (its look at the session never comes back empty). The run must
    // not be reported as a success, and what the command left behind is
    // stopped from outside, by the session the run was started with.
    { name: "failed-cleanup-is-a-failure", launcher: root.blind,
      argv: ["bash", "-c", "set -m; sleep 34.5678 >/dev/null 2>&1 & disown; echo done"],
      check: (c, o, e, ms) => c === 125 && o.trim() === "done" && e === subject.cleanupFailed && ms < 6000,
      gone: "sleep 34.5678" },
    // The cleanup from outside cannot confirm the session is empty either.
    { name: "unconfirmed-cleanup-is-reported", launcher: root.blind, cleaner: root.blindCleaner,
      argv: ["bash", "-c", "set -m; sleep 2.7183 >/dev/null 2>&1 & disown; echo done"],
      check: (c, o, e, ms) => c === 125 && e === subject.notConfirmed && ms < 9000 },
    { name: "runs-again-after-failed-cleanup", argv: ["printf", "again"],
      check: (c, o, e) => c === 0 && o === "again" },
    { name: "refuses-overlap", argv: ["sleep", "0.3"], overlap: true,
      check: (c, o, e) => c === 0 }
  ]

  // A shell that finds stand-ins for pgrep and pkill first (written next to
  // this file by the test): the look at the session always reports a process
  // and nothing is stopped, so a cleanup run by it can never be confirmed.
  readonly property string blindPath:
    "PATH=" + Qt.resolvedUrl("blind").toString().replace("file://", "") + ":" + Quickshell.env("PATH")
  readonly property var blind: ["setsid", "env", blindPath, "bash"]
  readonly property var blindCleaner: ["env", blindPath, "bash"]

  property bool overlapRefused: true
  property var pendingVerdict: null

  function next() {
    index += 1
    if (index >= cases.length) { console.log("DONE"); Qt.quit(); return }
    const t = cases[index]
    reports = 0
    subject.seconds = t.seconds || 5
    subject.maxBytes = t.maxBytes || 4096
    subject.graceSeconds = t.graceSeconds || 3
    subject.input = t.input || ""
    subject.launcher = t.launcher || ["setsid", "bash"]
    subject.cleaner = t.cleaner || ["bash"]
    began = Date.now()
    const accepted = subject.start(t.argv)
    if (!accepted) { report(t.name, false, "start() refused"); return }
    if (t.overlap) overlapRefused = subject.start(["true"]) === false
    if (t.cancelAfter) { canceller.interval = t.cancelAfter; canceller.restart() }
  }

  function report(name, ok, details) {
    console.log("CASE " + name + " " + (ok ? "PASS" : "FAIL") + " " + details)
    advance.restart()
  }

  BoundedRun {
    id: subject
    onFinished: function(code, output, errors) {
      root.reports += 1
      const t = root.cases[root.index]
      const ms = Date.now() - root.began
      let ok = t.check(code, output, errors, ms) && !subject.running
      if (t.overlap) ok = ok && root.overlapRefused
      const details = "code=" + code + " ms=" + ms + " out=" + JSON.stringify(output.slice(0, 40)) +
        " err=" + JSON.stringify(errors.slice(0, 60)) + " running=" + subject.running
      root.pendingVerdict = { name: t.name, ok: ok, details: details, gone: t.gone || "" }
      // Wait a moment: a second report for the same run would be a failure.
      verdict.restart()
    }
  }

  Timer { id: canceller; onTriggered: subject.cancel() }

  Timer {
    id: verdict
    interval: 900
    onTriggered: {
      const v = root.pendingVerdict
      if (root.reports !== 1) { root.report(v.name, false, "reported " + root.reports + " times; " + v.details); return }
      if (v.gone) { survivors.pattern = v.gone; survivors.running = true; return }
      root.report(v.name, v.ok, v.details)
    }
  }

  Process {
    id: survivors
    property string pattern: ""
    command: ["pgrep", "-fx", pattern]
    stdout: StdioCollector { id: found; waitForEnd: true }
    onExited: function(code) {
      const v = root.pendingVerdict
      const left = found.text.trim()
      root.report(v.name, v.ok && left === "", v.details + " left=" + JSON.stringify(left))
    }
  }

  Timer { id: advance; interval: 50; onTriggered: root.next() }
  Timer { interval: 100; running: true; onTriggered: root.next() }
  // The whole suite has its own limit.
  Timer { interval: 90000; running: true; onTriggered: { console.log("CASE suite FAIL timed out at " + root.index); Qt.quit() } }
}
