import QtQuick
import Quickshell
import Quickshell.Io

// One helper run that always ends, and ends exactly once.
//
// Every start() that returns true is answered by one `finished`, whatever
// happens: a normal exit, a helper that could not be started, or a run that
// overran. `finished` is sent only after the run's processes are gone, and
// start() returns false until then, so a new run never overlaps an old one.
//
// The command runs in its own session under a small supervisor:
//   - `timeout` limits the command and stops its process group;
//   - output is capped;
//   - when the run ends for any reason, the supervisor stops whatever is
//     still left in that session and waits until it is gone.
// If the supervisor itself overruns, the deadline here asks it to stop
// (which makes it clean up), and then stops the session from outside.
// A process that deliberately starts a new session of its own is outside
// this and is not tracked.
Scope {
  id: run

  property var argv: []
  property int seconds: 10
  property int maxBytes: 262144
  // Sent to the command's standard input when not empty.
  property string input: ""
  // Extra time, on top of `seconds`, before the deadline here steps in.
  property int graceSeconds: 3
  // The program that runs the supervisor script.
  property var launcher: ["bash"]

  // True from start() until the run is finished and its processes are gone.
  readonly property bool running: pending || proc.running || reaper.running

  signal finished(int exitCode, string output, string errors)

  // ---- State of the current attempt ----
  property bool pending: false     // started, `finished` not sent yet
  property bool began: false       // the process really started
  property bool decided: false     // the result is known
  property bool starting: false    // inside start()
  property bool abandoned: false   // gave up waiting for the process to go
  property int stage: 0            // 0 running, 1 asked to stop, 2 stopped from outside
  property int resultCode: 0
  property string resultOutput: ""
  property string resultErrors: ""
  property string stopReason: ""

  // Standard output is capped at `bytes`, standard error at 4 KB.
  readonly property string job:
    'set -o pipefail; limit=$1; bytes=$2; shift 2; ' +
    '{ { timeout -k 1 "$limit" "$@" 2>&4 3>&- 4>&- | head -c "$bytes" >&3 3>&- 4>&-; } 4>&1 | head -c 4096 >&2 3>&-; } 3>&1'

  // sweep: stop everything left in the job's session and wait until it is gone.
  readonly property string supervisor:
    'limit=$1; bytes=$2; job=$3; shift 3\n' +
    'setsid bash -c "$job" bash "$limit" "$bytes" "$@" <&0 &\n' +
    'sid=$!\n' +
    'sweep() { local n; for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do\n' +
    '  pgrep -s "$sid" >/dev/null 2>&1 || return 0; pkill -KILL -s "$sid" 2>/dev/null; sleep 0.05; done; return 1; }\n' +
    'trap \'sweep; wait "$sid" 2>/dev/null; exit 137\' TERM INT HUP\n' +
    'wait "$sid"; code=$?\n' +
    'trap "" TERM INT HUP\n' +
    'sweep\n' +
    'exit "$code"'

  function start(args) {
    if (running) return false
    if (args !== undefined) argv = args
    pending = true
    began = false
    decided = false
    abandoned = false
    stage = 0
    stopReason = "The helper did not finish in time."
    starting = true
    proc.command = launcher.concat(["-c", supervisor, "bash", String(seconds), String(maxBytes), job]).concat(argv)
    proc.running = true
    starting = false
    deadline.interval = (seconds + graceSeconds) * 1000
    deadline.restart()
    // A start that failed straight away is reported after start() returns.
    if (!proc.running && !began) decide(127, "", "The helper could not be started.")
    later.restart()
    return true
  }

  // Stop the current run early. `finished` still follows, once.
  function cancel() {
    if (!pending || stage > 0) return
    deadline.stop()
    stopReason = "The helper was stopped."
    stopRun()
  }

  function decide(code, output, errors) {
    if (!pending || decided) return
    decided = true
    resultCode = code
    resultOutput = output
    resultErrors = errors
    deliver()
  }

  // Send `finished` once the result is known and the processes are gone.
  function deliver() {
    if (!pending || !decided || starting) return
    if ((proc.running || reaper.running) && !abandoned) return
    pending = false
    deadline.stop()
    escalate.stop()
    lost.stop()
    run.finished(resultCode, resultOutput, resultErrors)
  }

  function stopRun() {
    if (!proc.running) { decide(124, out.text, stopReason); return }
    stage = 1
    proc.signal(15)
    escalate.interval = 2000
    escalate.restart()
  }

  Process {
    id: proc
    stdinEnabled: run.input.length > 0
    onStarted: {
      run.began = true
      if (run.input.length > 0) write(run.input)
    }
    stdout: StdioCollector { id: out; waitForEnd: true }
    stderr: StdioCollector { id: err; waitForEnd: true }
    onExited: function(exitCode) {
      lost.stop()
      const overran = run.stage > 0
      run.decide(overran && exitCode === 0 ? 124 : exitCode, out.text,
        overran ? run.stopReason : err.text)
      later.restart()
    }
    onRunningChanged: {
      if (running) return
      if (run.pending && !run.decided) {
        // No exit report: either the process never started, or the report is
        // still on its way. Give it a moment before treating it as lost.
        if (!run.began) run.decide(127, "", "The helper could not be started.")
        else lost.restart()
      }
      later.restart()
    }
  }

  // Stops a job session from outside when the supervisor did not do it.
  Process {
    id: reaper
    property bool began: false
    onStarted: began = true
    onRunningChanged: {
      if (running) return
      // Could not even start the cleanup: stop the supervisor directly.
      if (!began && proc.running) proc.signal(9)
      later.restart()
    }
  }

  Timer { id: later; interval: 0; onTriggered: run.deliver() }

  Timer {
    id: lost
    interval: 500
    onTriggered: run.decide(1, out.text, "The helper ended without a result.")
  }

  Timer {
    id: deadline
    onTriggered: if (run.pending && !run.decided) run.stopRun()
  }

  // After asking politely: stop the job's session and the supervisor from
  // outside. After that: report the failure even if something is still there;
  // `running` stays true, so no new run starts on top of it.
  Timer {
    id: escalate
    onTriggered: {
      if (!run.pending) return
      if (run.stage === 1 && proc.running) {
        run.stage = 2
        reaper.began = false
        reaper.command = ["bash", "-c",
          'for sid in $(pgrep -P "$1"); do pkill -KILL -s "$sid"; done; kill -KILL "$1"',
          "bash", String(proc.processId)]
        reaper.running = true
        interval = 2000
        restart()
        return
      }
      run.abandoned = true
      run.decide(124, out.text, run.stopReason)
      run.deliver()
    }
  }
}
