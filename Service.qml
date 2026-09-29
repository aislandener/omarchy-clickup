import QtQuick
import Quickshell.Io

// ClickUp data service. The helper owns the token, pagination and grouping;
// this item schedules it and exposes one stable, defensive model to the panel.
Item {
  id: root

  property var settings: ({})
  property bool loading: false
  property string state: "loading"
  property string message: "Loading ClickUp…"
  property string fetchedAt: ""
  property int totalOpen: 0
  property int overdue: 0
  property int dueToday: 0
  // The running time entry: { taskId, taskName, start } or null.
  property var timer: null
  property double now: Date.now()
  property string currentSprint: ""
  property var sections: []
  property var listStatuses: ({})
  property string teamId: ""
  property var workspaces: []
  property var warnings: []
  // Set while the panel has a picker open on a row. A refresh landing then
  // would rebuild the rows under it and close the picker mid-choice, so the
  // result waits instead.
  property bool holdRefresh: false
  property string _deferred: ""
  property bool refreshQueued: false
  property string actionStatus: ""
  property string _stdout: ""
  property string _stderr: ""
  property string _writeStdout: ""
  property string _writeStderr: ""
  // Token saving and status changes share one process, so the panel gates
  // every entry point on this rather than on whichever call it happens to
  // make. An entry point added later inherits the guard instead of knowing.
  readonly property bool busy: writeProcess.running
  readonly property bool tokenMissing: state === "unconfigured" || state === "auth-error"
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 600, 60, 3600)
  readonly property int maxRowsPerSection: intSetting("maxRowsPerSection", 5, 3, 50)
  // Something already past its due date is the reason to light the bar icon;
  // a full backlog is not news.
  readonly property bool alarming: overdue > 0
  readonly property bool timing: timer !== null && Number(timer.start) > 0

  signal tokenAccepted()

  function elapsedLabel(withSeconds) {
    if (!timing)
      return "";

    var total = Math.max(0, Math.floor((now - Number(timer.start)) / 1000));
    var h = Math.floor(total / 3600);
    var m = Math.floor(total / 60) % 60;
    var label = h + ":" + (m < 10 ? "0" : "") + m;
    if (withSeconds)
      label += ":" + (total % 60 < 10 ? "0" : "") + (total % 60);

    return label;
  }

  function isTimed(taskId) {
    return timing && String(timer.taskId) === String(taskId);
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined;
    return value === undefined || value === null ? fallback : value;
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10);
    if (!isFinite(value))
      value = fallback;

    return Math.max(minimum, Math.min(maximum, value));
  }

  function helperPath() {
    return Qt.resolvedUrl("omarchy-clickup-fetch").toString().replace(/^file:\/\//, "");
  }

  function statusesFor(listId) {
    var rows = listStatuses ? listStatuses[String(listId)] : undefined;
    return Array.isArray(rows) ? rows : [];
  }

  function refresh() {
    if (fetchProcess.running || writeProcess.running) {
      refreshQueued = true;
      return ;
    }
    refreshQueued = false;
    loading = true;
    _stdout = "";
    _stderr = "";
    fetchProcess.command = [helperPath(), "--status-order", String(setting("statusOrder", ""))];
    fetchProcess.running = true;
  }

  function apply(raw) {
    try {
      var data = JSON.parse(String(raw || ""));
      state = String(data.state || "error");
      message = String(data.message || "");
      fetchedAt = String(data.fetchedAt || "");
      totalOpen = Number(data.totalOpen) || 0;
      overdue = Number(data.overdue) || 0;
      dueToday = Number(data.dueToday) || 0;
      timer = data.timer && typeof data.timer === "object" ? data.timer : null;
      currentSprint = String(data.currentSprint || "");
      sections = Array.isArray(data.sections) ? data.sections : [];
      listStatuses = data.listStatuses && typeof data.listStatuses === "object" ? data.listStatuses : ({
      });
      teamId = String(data.teamId || "");
      workspaces = Array.isArray(data.workspaces) ? data.workspaces : [];
      warnings = Array.isArray(data.warnings) ? data.warnings : [];
    } catch (error) {
      state = "error";
      message = "ClickUp returned an unreadable response.";
      sections = [];
      warnings = [String(error)];
    }
  }

  function setStatus(taskId, status) {
    var id = String(taskId || "");
    var next = String(status || "");
    if (id === "" || next === "")
      return ;

    // A refresh in flight is no reason to drop the change: its result is
    // superseded by the refresh this write queues. Only a write in flight is,
    // and dropping one silently looked exactly like success.
    actionStatusTimer.stop();
    if (writeProcess.running) {
      actionStatus = "Still saving the previous change. Try again in a moment.";
      actionStatusTimer.restart();
      return ;
    }

    actionStatus = "Moving to " + next + "…";
    _writeStdout = "";
    _writeStderr = "";
    writeProcess.savingToken = false;
    writeProcess.command = [helperPath(), "--set-status", id, next];
    writeProcess.running = true;
  }

  function setTeam(id) {
    var next = String(id || "");
    if (next === "" || next === teamId || loading || fetchProcess.running || writeProcess.running)
      return ;

    actionStatusTimer.stop();
    actionStatus = "Switching workspace…";
    _writeStdout = "";
    _writeStderr = "";
    writeProcess.savingToken = false;
    writeProcess.command = [helperPath(), "--set-team", next];
    writeProcess.running = true;
  }

  // Only another write is a conflict: a refresh in flight just lands a
  // moment later, and the refresh after this write corrects it.
  function runTimer(args, label) {
    if (writeProcess.running)
      return ;

    actionStatusTimer.stop();
    actionStatus = label;
    _writeStdout = "";
    _writeStderr = "";
    writeProcess.savingToken = false;
    writeProcess.command = [helperPath()].concat(teamId !== "" ? ["--team", teamId] : []).concat(args);
    writeProcess.running = true;
  }

  function startTimer(taskId) {
    if (String(taskId || "") !== "")
      runTimer(["--timer-start", String(taskId)], "Starting the timer…");
  }

  function stopTimer() {
    runTimer(["--timer-stop"], "Stopping the timer…");
  }

  // A timer started on the web or the phone shows up here within a minute,
  // without paying for a full task refresh.
  function pollTimer() {
    if (timerProcess.running || tokenMissing || state !== "ready")
      return ;

    timerProcess.command = [helperPath()].concat(teamId !== "" ? ["--team", teamId] : []).concat(["--timer"]);
    timerProcess.running = true;
  }

  // The token goes in over stdin, never in the argument list, where any
  // process on the machine could read it out of ps.
  function saveToken(value) {
    var token = String(value || "").trim();
    if (token === "" || writeProcess.running)
      return ;

    actionStatusTimer.stop();
    actionStatus = "Checking the token…";
    _writeStdout = "";
    _writeStderr = "";
    writeProcess.savingToken = true;
    writeProcess.pendingToken = token;
    writeProcess.command = [helperPath(), "--save-token"];
    writeProcess.stdinEnabled = true;
    writeProcess.running = true;
  }

  visible: false

  onHoldRefreshChanged: {
    if (holdRefresh || _deferred === "")
      return ;

    var raw = _deferred;
    _deferred = "";
    apply(raw);
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!root.holdRefresh) root.refresh()
  }

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.pollTimer()
  }

  // Ticks only while something is being timed, for the elapsed label.
  Timer {
    interval: 1000
    repeat: true
    running: root.timing
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  Timer {
    id: actionStatusTimer

    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: fetchProcess

    running: false
    command: []
    onExited: function(exitCode) {
      root.loading = false;
      var stdout = String(output.text || root._stdout || "");
      var stderr = String(errors.text || root._stderr || "").trim();
      if (stdout.trim() !== "") {
        if (root.holdRefresh)
          root._deferred = stdout;
        else
          root.apply(stdout);
      } else {
        root.state = "error";
        root.message = stderr !== "" ? stderr : "ClickUp refresh failed.";
      }
      if (root.refreshQueued) {
        root.refreshQueued = false;
        Qt.callLater(root.refresh);
      }
    }

    stdout: StdioCollector {
      id: output

      waitForEnd: true
      onStreamFinished: root._stdout = text
    }

    stderr: StdioCollector {
      id: errors

      waitForEnd: true
      onStreamFinished: root._stderr = text
    }

  }

  Process {
    id: writeProcess

    property bool savingToken: false
    property string pendingToken: ""

    running: false
    command: []
    // Writing before the process exists drops the data, so the token goes in
    // here rather than next to the command. Closing stdin afterwards is what
    // sends EOF; the helper is waiting on exactly one line.
    onStarted: {
      if (pendingToken !== "") {
        write(pendingToken + "\n");
        pendingToken = "";
        stdinEnabled = false;
      }
    }
    onExited: function(exitCode) {
      var response = null;
      try {
        response = JSON.parse(String(writeOutput.text || root._writeStdout || ""));
      } catch (error) {
      }
      var ok = exitCode === 0 && response && response.state === "ready";
      if (ok) {
        root.actionStatus = response.message ? String(response.message) : "Done.";
        if (savingToken)
          root.tokenAccepted();

      } else {
        var fallback = savingToken ? "Could not save the token." : "Could not reach ClickUp.";
        root.actionStatus = response && response.message ? String(response.message) : String(writeErrors.text || root._writeStderr || fallback).trim();
      }
      savingToken = false;
      actionStatusTimer.restart();
      // ClickUp is authoritative after every attempt, successful or not. The
      // timer poll answers in one request, well before the full refresh.
      root.refreshQueued = false;
      Qt.callLater(root.pollTimer);
      Qt.callLater(root.refresh);
    }

    stdout: StdioCollector {
      id: writeOutput

      waitForEnd: true
      onStreamFinished: root._writeStdout = text
    }

    stderr: StdioCollector {
      id: writeErrors

      waitForEnd: true
      onStreamFinished: root._writeStderr = text
    }

  }

  // A failed poll keeps the last known timer rather than blanking the bar;
  // the next full refresh reports the error.
  Process {
    id: timerProcess

    running: false
    command: []

    // Parsed here rather than in onExited: the stream can finish after the
    // process does, and only a "ready" answer is trusted.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || ""));
          if (data.state === "ready")
            root.timer = data.timer && typeof data.timer === "object" ? data.timer : null;

        } catch (error) {
        }
      }
    }

  }

}
