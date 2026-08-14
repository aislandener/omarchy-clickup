import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "aislandener.clickup"
  ipcTarget: "aislandener.clickup"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string tokenUrl: "https://app.clickup.com/settings/apps"

  property string query: ""
  property var expandedStatuses: ({})
  property bool cursorActive: false
  property int cursorIndex: 0
  property bool tokenView: false
  property string statusEditingId: ""
  // Tracks the picker's real popup rather than the intent to open one. Gating
  // the key catcher on the intent meant a popup that failed to open left the
  // panel deaf to every key, including the one that would have cleared it.
  property bool statusPopupOpen: false

  readonly property bool showingSetup: tokenView || clickup.tokenMissing
  readonly property var visibleSections: buildSections()
  readonly property var cursorTargets: buildCursorTargets()
  readonly property var selectedTask: cursorTargets.length > 0
    ? cursorTargets[Math.max(0, Math.min(cursorIndex, cursorTargets.length - 1))]
    : null

  function matchesQuery(task) {
    var needle = String(query || "").trim().toLowerCase()
    if (needle === "") return true
    var haystack = [task.name, task.listName, task.folderName, task.status, (task.tags || []).join(" ")].join(" ")
    return haystack.toLowerCase().indexOf(needle) !== -1
  }

  function buildSections() {
    var out = []
    for (var i = 0; i < clickup.sections.length; i++) {
      var section = clickup.sections[i]
      var all = (section.tasks || []).filter(function(task) { return root.matchesQuery(task) })
      if (all.length === 0) continue
      var expanded = expandedStatuses[section.status] === true
      out.push({
        status: section.status,
        total: all.length,
        expanded: expanded,
        tasks: expanded ? all : all.slice(0, clickup.maxRowsPerSection)
      })
    }
    return out
  }

  function buildCursorTargets() {
    var targets = []
    for (var i = 0; i < visibleSections.length; i++)
      for (var j = 0; j < visibleSections[i].tasks.length; j++)
        targets.push(visibleSections[i].tasks[j])
    return targets
  }

  // A plain assignment to a sub-key would not re-evaluate the bindings that
  // read it, so section state is replaced wholesale.
  function toggleSection(status) {
    var next = {}
    for (var key in expandedStatuses) next[key] = expandedStatuses[key]
    next[status] = !(next[status] === true)
    expandedStatuses = next
  }

  function selectedId() { return selectedTask ? String(selectedTask.id) : "" }

  function selectId(id) {
    for (var i = 0; i < cursorTargets.length; i++) {
      if (String(cursorTargets[i].id) === String(id)) { cursorActive = true; cursorIndex = i; return }
    }
  }

  function ensureCursor() {
    if (cursorTargets.length === 0) { cursorIndex = 0; return }
    cursorIndex = Math.max(0, Math.min(cursorIndex, cursorTargets.length - 1))
  }

  function moveCursor(delta) {
    cursorActive = true
    if (cursorTargets.length === 0) return
    cursorIndex = Math.max(0, Math.min(cursorTargets.length - 1, cursorIndex + delta))
  }

  function activateCursor() {
    if (selectedTask) openUrl(selectedTask.url, false)
  }

  // Moving focus inside a key handler is not enough on its own: the same press
  // goes on to the panel, which reads Enter as "open this task". Deferring the
  // focus change lets the current event finish in the field it was typed in.
  function focusList() {
    cursorActive = true
    cursorIndex = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Opening the picker writes nothing, so a refresh in flight must not swallow
  // the key: only the chosen status is a write, and setStatus() guards that.
  // Activating the cursor first means the row about to change is the
  // highlighted one, rather than an undrawn default at the top of the list.
  function editSelectedStatus() {
    if (!selectedTask || clickup.busy) return
    // Pressing it again on the same row closes the picker, so the key is never
    // a dead end.
    if (statusEditingId === String(selectedTask.id)) { statusEditingId = ""; return }
    if (clickup.statusesFor(selectedTask.listId).length === 0) return
    cursorActive = true
    statusEditingId = String(selectedTask.id)
  }

  function openUrl(url, keepOpen) {
    var value = String(url || "")
    if (value === "") return
    Quickshell.execDetached(["omarchy-launch-browser", value])
    if (!keepOpen) close()
  }

  // Whole days rather than elapsed hours: "due today" has to stay true all day.
  function dayDelta(value) {
    var due = new Date(Number(value))
    due.setHours(0, 0, 0, 0)
    var today = new Date()
    today.setHours(0, 0, 0, 0)
    return Math.round((due.getTime() - today.getTime()) / 86400000)
  }

  function dueLabel(task) {
    if (task.dueDate === null || task.dueDate === undefined || task.dueDate === "") return ""
    var days = dayDelta(task.dueDate)
    if (days < -1) return (-days) + " days overdue"
    if (days === -1) return "1 day overdue"
    if (days === 0) return "due today"
    if (days === 1) return "due tomorrow"
    if (days < 7) return "due in " + days + " days"
    return "due " + Qt.formatDate(new Date(Number(task.dueDate)), "d MMM")
  }

  function taskDetail(task) {
    var parts = []
    var place = task.folderName !== "" ? task.folderName + "/" + task.listName : task.listName
    if (place !== "") parts.push(place)
    var due = dueLabel(task)
    if (due !== "") parts.push(due)
    if (task.sprintLabel !== "") parts.push(task.sprintLabel)
    return parts.join(" · ")
  }

  function heroMeta() {
    if (clickup.loading && clickup.totalOpen === 0) return "Loading your tasks…"
    if (clickup.state !== "ready") return clickup.message
    if (clickup.totalOpen === 0) return "No open tasks assigned to you."
    var parts = [clickup.totalOpen + " open"]
    if (clickup.overdue > 0) parts.push(clickup.overdue + " overdue")
    if (clickup.dueToday > 0) parts.push(clickup.dueToday + " due today")
    if (clickup.currentSprint !== "") parts.push(clickup.currentSprint)
    return parts.join(" · ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    statusEditingId = ""
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      tokenView = false
      if (panelFlick) panelFlick.contentY = 0
      clickup.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  onCursorTargetsChanged: ensureCursor()

  Service {
    id: clickup
    settings: root.settings
    holdRefresh: root.statusEditingId !== ""
    onTokenAccepted: {
      root.tokenView = false
      tokenField.text = ""
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { clickup.refresh(); return "ok" }
    function status(): string { return clickup.state }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-tasks
    text: "\uf0ae"
    active: clickup.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) clickup.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: search.activeFocus || tokenField.activeFocus || root.statusPopupOpen || workspacePicker.popupOpen
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { search.forceActiveFocus() }
      onTextKey: function(text) {
        if (text === "r" || text === "R") clickup.refresh()
        else if (text === "/") Qt.callLater(function() { search.forceActiveFocus() })
        else if (text === "s" || text === "S") root.editSelectedStatus()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "ClickUp"
            meta: root.showingSetup ? "Connect your account" : root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "\uf0ae"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
              }
            }
          }

          Text {
            visible: clickup.actionStatus !== ""
            width: parent.width
            text: clickup.actionStatus
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // Setup: the token never reaches this file's process arguments; the
          // service hands it to the helper over stdin.
          Column {
            visible: root.showingSetup
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: clickup.state === "auth-error"
                ? "ClickUp rejected the stored token. Generate a new one and paste it below."
                : "In ClickUp, open Settings → Apps and generate a personal API token. It starts with pk_."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              text: "Open the token page"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.openUrl(root.tokenUrl, true)
            }

            TextField {
              id: tokenField
              width: parent.width
              password: true
              placeholderText: "pk_…"
              foreground: root.foreground
              enabled: !clickup.busy
              onAccepted: clickup.saveToken(text)
            }

            Button {
              text: clickup.busy ? "Checking…" : "Save token"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !clickup.busy && tokenField.text !== ""
              onClicked: clickup.saveToken(tokenField.text)
            }
          }

          BorderSurface {
            visible: !root.showingSetup && (clickup.state !== "ready" || clickup.warnings.length > 0)
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.space(20)
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              text: {
                if (clickup.state !== "ready") return clickup.message
                var summary = "Partial results · " + String(clickup.warnings[0] || "A ClickUp request failed.")
                if (clickup.warnings.length > 1) summary += " · " + (clickup.warnings.length - 1) + " more"
                return summary
              }
              textFormat: Text.PlainText
              color: clickup.state === "ready" ? root.dim : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // Sits with the filter rather than in the footer: it says which
          // account the list below belongs to, and a footer control would need
          // scrolling past every task to reach. Only worth the space when
          // there is more than one workspace to switch between.
          Dropdown {
            id: workspacePicker
            visible: !root.showingSetup && clickup.workspaces.length > 1
            width: parent.width
            label: "WORKSPACE"
            value: clickup.teamId
            // Two workspaces can carry the same name, which makes the picker
            // unusable; the id only shows up on the ones that collide.
            options: clickup.workspaces.map(function(row, index, all) {
              var name = String(row.name || row.id)
              var ambiguous = all.filter(function(other) { return String(other.name || other.id) === name }).length > 1
              return { value: String(row.id), label: ambiguous ? name + " (" + row.id + ")" : name }
            })
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(value) { clickup.setTeam(value) }
            // Qt focus stays on the trigger after the popup closes, which would
            // send every later keystroke to a closed dropdown instead of here.
            onPopupOpenChanged: if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
          }

          TextField {
            id: search
            visible: !root.showingSetup && clickup.totalOpen > 0
            width: parent.width
            placeholderText: "Filter tasks"
            foreground: root.foreground
            text: root.query
            onTextChanged: root.query = text
            // Enter hands the keyboard to the list, on the first match, so
            // filtering and then acting on a result is one continuous move.
            // Accepting the event here stops it from also reaching the panel.
            Keys.onReturnPressed: function(event) { root.focusList(); event.accepted = true }
            Keys.onEnterPressed: function(event) { root.focusList(); event.accepted = true }
            Keys.onEscapePressed: function(event) {
              root.query = ""
              keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }

          Text {
            visible: !root.showingSetup && clickup.state === "ready" && root.visibleSections.length === 0
            width: parent.width
            text: clickup.totalOpen === 0 ? "Nothing assigned to you. Enjoy it." : "No task matches this filter."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            model: root.showingSetup ? [] : root.visibleSections

            TaskSection {
              required property var modelData
              width: content.width
              section: modelData
            }
          }

          PanelSeparator {
            visible: !root.showingSetup
            width: parent.width
            foreground: root.foreground
          }

          Item {
            visible: !root.showingSetup
            width: parent.width
            implicitHeight: Math.max(hints.implicitHeight, tokenButton.implicitHeight)

            Text {
              id: hints
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "↑↓ move · ↵ open · s status · / filter · r refresh"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              id: tokenButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Change token"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.tokenView = true
            }
          }
        }
      }
    }
  }

  component TaskSection: Column {
    id: sectionItem

    property var section: null

    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: sectionHeader.implicitHeight

      PanelSectionHeader {
        id: sectionHeader
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: String(sectionItem.section.status).toUpperCase()
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: sectionItem.section.expanded || sectionItem.section.total <= sectionItem.section.tasks.length
          ? String(sectionItem.section.total)
          : sectionItem.section.tasks.length + "/" + sectionItem.section.total
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          cursorShape: Qt.PointingHandCursor
          enabled: sectionItem.section.total > sectionItem.section.tasks.length || sectionItem.section.expanded
          onClicked: root.toggleSection(sectionItem.section.status)
        }
      }
    }

    Repeater {
      model: sectionItem.section.tasks

      TaskRow {
        required property var modelData
        width: sectionItem.width
        task: modelData
      }
    }
  }

  component TaskRow: CursorSurface {
    id: rowItem

    property var task: null
    readonly property bool editing: root.statusEditingId === String(rowItem.task.id)

    width: parent ? parent.width : 0
    implicitHeight: rowColumn.implicitHeight + Style.space(12)
    foreground: root.foreground
    hasCursor: root.cursorActive && root.selectedId() === String(rowItem.task.id)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onEntered: root.selectId(rowItem.task.id)
      onClicked: function(mouse) {
        root.selectId(rowItem.task.id)
        if (mouse.button === Qt.RightButton) root.editSelectedStatus()
        else root.openUrl(rowItem.task.url, false)
      }
    }

    Column {
      id: rowColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: rowItem.task.name
        textFormat: Text.PlainText
        color: rowItem.task.overdue ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: root.taskDetail(rowItem.task)
        textFormat: Text.PlainText
        color: rowItem.task.overdue ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Loader {
        width: parent.width
        active: rowItem.editing
        visible: active
        sourceComponent: Component {
          Dropdown {
            property bool everOpened: false

            width: rowItem.width - Style.space(20)
            showLabel: false
            value: String(rowItem.task.status)
            options: clickup.statusesFor(rowItem.task.listId).map(function(row) { return String(row.status) })
            foreground: root.foreground
            fontFamily: root.fontFamily
            Component.onCompleted: Qt.callLater(open)
            Component.onDestruction: root.statusPopupOpen = false
            onPopupOpenChanged: {
              root.statusPopupOpen = popupOpen
              if (popupOpen) everOpened = true
              // Dismissed without choosing: give the keys back to the panel.
              else if (everOpened && root.statusEditingId === String(rowItem.task.id)) root.statusEditingId = ""
            }
            onChanged: function(value) {
              root.statusEditingId = ""
              if (value !== String(rowItem.task.status)) clickup.setStatus(rowItem.task.id, value)
            }
          }
        }
      }
    }
  }
}
