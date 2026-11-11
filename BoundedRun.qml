import QtQuick
import Quickshell
import Quickshell.Io

// One helper run that always ends, and ends exactly once.
//
// Every start() that returns true is answered by one `finished`, whatever
// happens: a normal exit, a helper that could not be started, or a run that
// overran. start() returns false while a run or its cleanup is in progress.
//
// The run is one session, and the supervisor is its leader, so the session
// has the supervisor's process ID. That ID is known here from the moment the
// run starts and does not depend on any process in the session staying alive.
//   - `timeout` limits the command and stops its process group;
//   - output is capped;
//   - when the command ends for any reason, the supervisor stops whatever is
//     still left in the session and checks that nothing is.
//
// The supervisor ends normally only after that check passed. If it ends any
// other way (the check failed, or it was killed), or does not stop when
// asked, the session is stopped and checked from here instead.
//
// What `finished` reports:
//   - the command's own exit code, when the supervisor confirmed the cleanup;
//   - 124 with a reason, when the run was stopped (deadline or cancel());
//   - 125 `cleanupFailed`, when the supervisor did not confirm its cleanup
//     and the session was stopped from here;
//   - 125 `notConfirmed`, when the session could not be confirmed empty.
//     Nothing more can be done about such a run, so a later start() is
//     accepted once the supervisor itself is gone.
//   - 127, when the helper could not be started.
//
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
  // Starts the supervisor script as the leader of a new session.
  property var launcher: ["setsid", "bash"]
  // Runs the cleanup that is done from here.
  property var cleaner: ["bash"]

  // True from start() until the run is finished and its processes are gone.
  readonly property bool running: pending || proc.running || sweeper.running

  signal finished(int exitCode, string output, string errors)

  readonly property string notStarted: "The helper could not be started."
  readonly property string cleanupFailed: "The helper ended without cleaning up; what it left was stopped."
  readonly property string notConfirmed: "The helper's processes could not be confirmed stopped."

  // ---- State of the current attempt ----
  property bool pending: false     // started, `finished` not sent yet
  property bool began: false       // the supervisor really started
  property bool starting: false    // inside start()
  property bool asked: false       // asked to stop (deadline or cancel)
  property int session: 0          // the run's session: the supervisor's process ID
  property int ended: 0            // supervisor: 0 not ended, 1 ended normally, 2 any other way
  property int endCode: 0
  property bool endAsked: false    // it had been asked to stop when it ended
  property int sweep: 0            // cleanup from here: 0 not needed, 1 running, 2 confirmed, 3 failed
  property string stopReason: ""

  // Standard output is capped at `bytes`, standard error at 4 KB.
  readonly property string job:
    'set -o pipefail; limit=$1; bytes=$2; shift 2; ' +
    '{ { timeout -k 1 "$limit" "$@" 2>&4 3>&- 4>&- | head -c "$bytes" >&3 3>&- 4>&-; } 4>&1 | head -c 4096 >&2 3>&-; } 3>&1'

  // sweep: stop everything else in this session; succeeds only once a look
  // at the session shows nothing but the supervisor. (`exec`, so the look is
  // one process, which pgrep leaves out, and not a subshell that it lists.)
  // Ending with SIGKILL instead of `exit` is how "cleanup not confirmed" is
  // reported: no exit code of the command can be mistaken for it.
  readonly property string supervisor:
    'limit=$1; bytes=$2; job=$3; shift 3\n' +
    'read -r _ _ _ _ _ sid _ </proc/$$/stat\n' +
    '{ read -r parent </proc/$PPID/comm; } 2>/dev/null\n' +
    'if [ "$sid" != "$$" ] || [ -z "$parent" ] || [ "$parent" = setsid ]; then\n' +
    '  echo "The helper could not be given a session of its own." >&2; exit 126; fi\n' +
    'bash -c "$job" bash "$limit" "$bytes" "$@" <&0 &\n' +
    'job_pid=$!\n' +
    'sweep() { local n p list rest; for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do\n' +
    '  list=$(exec pgrep -s "$$") || return 1; rest=0\n' +
    '  for p in $list; do [ "$p" = "$$" ] || { rest=1; kill -KILL "$p" 2>/dev/null; }; done\n' +
    '  [ "$rest" = 0 ] && return 0\n' +
    '  wait "$job_pid" 2>/dev/null; sleep 0.05; done; return 1; }\n' +
    'trap \'sweep && exit 137; kill -KILL "$$"\' TERM INT HUP\n' +
    'wait "$job_pid"; code=$?\n' +
    'trap "" TERM INT HUP\n' +
    'sweep || kill -KILL "$$"\n' +
    'exit "$code"'

  // Stops session $1, its leader included, and succeeds only once a look at
  // the session shows nothing left in it.
  readonly property string sweepScript:
    'for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do\n' +
    '  pkill -KILL -s "$1" 2>/dev/null\n' +
    '  pgrep -s "$1" >/dev/null 2>&1; [ "$?" = 1 ] && exit 0\n' +
    '  sleep 0.05; done; exit 1'

  function start(args) {
    if (running) return false
    if (args !== undefined) argv = args
    pending = true
    began = false
    asked = false
    session = 0
    ended = 0
    sweep = 0
    stopReason = "The helper did not finish in time."
    starting = true
    proc.command = launcher.concat(["-c", supervisor, "bash", String(seconds), String(maxBytes), job]).concat(argv)
    proc.running = true
    starting = false
    deadline.interval = (seconds + graceSeconds) * 1000
    deadline.restart()
    // A start that failed straight away is reported after start() returns.
    later.restart()
    return true
  }

  // Stop the current run early. `finished` still follows, once.
  function cancel() {
    if (!pending || asked) return
    deadline.stop()
    stopReason = "The helper was stopped."
    stopRun()
  }

  function stopRun() {
    asked = true
    if (!proc.running) { later.restart(); return }
    proc.signal(15)
    escalate.interval = 2000
    escalate.restart()
  }

  // Stop the run's session from here and check that it is empty.
  function startSweep() {
    sweep = 1
    sweeper.began = false
    sweeper.command = cleaner.concat(["-c", sweepScript, "bash", String(session)])
    sweeper.running = true
    escalate.interval = 5000
    escalate.restart()
  }

  // Send `finished` once the outcome is known and nothing is running.
  function conclude() {
    if (!pending || starting) return
    if (proc.running || sweeper.running) return
    if (!began) { finish(127, "", notStarted); return }
    if (ended === 0 || sweep === 1) return   // a report is still on its way
    if (ended === 1) {
      // The supervisor confirmed that nothing is left.
      finish(endAsked ? 124 : endCode, out.text, endAsked ? stopReason : err.text)
      return
    }
    if (sweep === 0) { startSweep(); return }
    if (sweep === 2) finish(asked ? 124 : 125, out.text, asked ? stopReason : cleanupFailed)
    else finish(125, out.text, notConfirmed)
  }

  function finish(code, output, errors) {
    pending = false
    deadline.stop()
    escalate.stop()
    lost.stop()
    run.finished(code, output, errors)
  }

  Process {
    id: proc
    stdinEnabled: run.input.length > 0
    onStarted: {
      run.began = true
      run.session = processId
      if (run.input.length > 0) write(run.input)
    }
    stdout: StdioCollector { id: out; waitForEnd: true }
    stderr: StdioCollector { id: err; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      lost.stop()
      if (run.pending && run.ended === 0) {
        run.ended = exitStatus === 0 ? 1 : 2
        run.endCode = exitCode
        run.endAsked = run.asked
      }
      later.restart()
    }
    onRunningChanged: {
      if (running) return
      // No exit report yet: either the process never started, or the report
      // is still on its way. Give it a moment before treating it as lost.
      if (run.pending && run.began && run.ended === 0) lost.restart()
      later.restart()
    }
  }

  Process {
    id: sweeper
    property bool began: false
    onStarted: began = true
    onExited: function(exitCode, exitStatus) {
      if (run.sweep === 1) run.sweep = exitStatus === 0 && exitCode === 0 ? 2 : 3
      later.restart()
    }
    onRunningChanged: {
      if (running) return
      if (!began) {
        // Could not even start the cleanup: stop the supervisor directly.
        if (run.sweep === 1) run.sweep = 3
        if (proc.running) proc.signal(9)
      }
      later.restart()
    }
  }

  Timer { id: later; interval: 0; onTriggered: run.conclude() }

  // The supervisor went away without an exit report: its cleanup is unknown.
  Timer {
    id: lost
    interval: 500
    onTriggered: {
      if (run.pending && run.ended === 0) run.ended = 2
      run.conclude()
    }
  }

  Timer {
    id: deadline
    onTriggered: if (run.pending && !run.asked) run.stopRun()
  }

  // After asking politely: stop the session from here. If that does not end
  // it either, report the failure; `running` stays true while the supervisor
  // is still there, so no new run starts on top of it.
  Timer {
    id: escalate
    onTriggered: {
      if (!run.pending) return
      if (run.sweep === 0 && proc.running) { run.startSweep(); return }
      run.finish(125, out.text, run.notConfirmed)
    }
  }
}
