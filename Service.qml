import QtQuick
import Quickshell
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

  signal tokenAccepted()

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
    if (id === "" || next === "" || loading || fetchProcess.running || writeProcess.running)
      return ;

    actionStatusTimer.stop();
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
      // ClickUp is authoritative after every attempt, successful or not.
      root.refreshQueued = false;
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

}
