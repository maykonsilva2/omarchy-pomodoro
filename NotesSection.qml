import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Persistent notepad for the pomodoro widget.
//
// Local addition -- not part of upstream omarchy-pomodoro. Everything the
// feature needs lives in this file on purpose: the patch against upstream is
// then a handful of lines in BarWidget.qml (the instance plus the IPC entry
// point), which keeps a future `git pull`/rebase conflict-free.
//
// Two surfaces:
//   * the preview block (this Item's own content) sits inside the popup's
//     Column and shows the first lines of the note plus a way into the editor;
//   * the editor is a PanelWindow claiming WlrKeyboardFocus.Exclusive while
//     it is open. It cannot be a bar popup: a popup is an xdg-popup hanging
//     off a layer surface and never receives keyboard events (verified --
//     synthetic Esc and typed text never arrive), so typing would be lost.
//
// Storage: ~/.local/share/omarchy/pomodoro/notes.md, plain markdown, created on
// first save and freely editable outside the shell. Reads happen when a surface
// opens; writes are debounced 800 ms and flushed when the editor closes, via a
// write-only FileView with atomicWrites (the pattern Service.qml uses for its
// state file).
Item {
  id: root

  // The BarWidget root (palette, font, screen) and the bar itself.
  property var host: null
  property var bar: null

  // Bound to the popup's open flag: refreshes the preview and flushes pending
  // words when the card goes away.
  property bool previewVisible: false

  readonly property color fg: host ? host.fg : Color.foreground
  readonly property color accent: host ? host.accent : Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string notesDir: Quickshell.env("HOME") + "/.local/share/omarchy/pomodoro"
  readonly property string notesPath: notesDir + "/notes.md"

  property bool editorOpen: false
  property string notesText: ""        // last content read from / written to the file
  property bool notesDirty: false
  property bool notesAdopting: false

  readonly property bool notesEmpty: notesText.trim().length === 0
  readonly property string notesPreview: notesEmpty
    ? "Click to write — kept between sessions"
    : notesText

  readonly property var screen: host && host.QsWindow && host.QsWindow.window
    ? host.QsWindow.window.screen : null

  implicitHeight: column.implicitHeight
  height: implicitHeight

  // ------------------------------------------------------------------ file

  // The file keeps a trailing newline; the editor does not show it.
  function notesView(raw) {
    return String(raw === undefined || raw === null ? "" : raw).replace(/\n$/, "")
  }

  // Feed the file into the editor, but never clobber unsaved words: a reload
  // that lands while something is dirty loses to what the user typed.
  function notesLoaded(raw) {
    var incoming = notesView(raw)
    root.notesText = incoming
    if (!editorText) return
    if (root.notesDirty) return
    if (editorText.text === incoming) return
    root.notesAdopting = true
    editorText.text = incoming
    editorText.cursorPosition = incoming.length
    root.notesAdopting = false
  }

  function notesSave() {
    if (!editorText) return
    var body = String(editorText.text).replace(/\n+$/, "")
    notesWriter.setText(body.length > 0 ? body + "\n" : "")
    root.notesText = body
    root.notesDirty = false
  }

  function openEditor() {
    // Close the popup card first, and ONLY the card: it is an xdg-popup of the
    // bar and stacks ABOVE this panel's layer surface, so leaving it up would
    // bury the editor. host.close() would be wrong here — it dismisses
    // whichever surface is up, and prefers the editor.
    if (host && host.popupOpen) host.popupOpen = false
    // Pick up edits made outside the shell, then show the editor.
    notesReader.reload()
    root.editorOpen = true
  }

  function closeEditor() {
    notesSaveTimer.stop()
    if (root.notesDirty) root.notesSave()
    root.editorOpen = false
  }

  FileView {
    id: notesReader
    path: root.notesPath
    preload: true
    watchChanges: false
    printErrors: false
    onLoaded: root.notesLoaded(text())
    onLoadFailed: root.notesLoaded("")
  }

  FileView {
    id: notesWriter
    path: root.notesPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  Timer {
    id: notesSaveTimer
    interval: 800
    onTriggered: root.notesSave()
  }

  onPreviewVisibleChanged: {
    if (previewVisible) { notesReader.reload(); return }
    // The card went away: flush whatever is pending. Deliberately does NOT
    // close the editor — the card is closed *by* openEditor() when the editor
    // comes up, and leaving this coupled to the card's flag killed the editor
    // the moment the card was dismissed.
    notesSaveTimer.stop()
    if (root.notesDirty) root.notesSave()
  }

  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", root.notesDir])

  // ------------------------------------------------------------------ preview

  Column {
    id: column
    width: root.width
    spacing: Style.space(10)

    Item {
      width: parent.width
      height: Math.max(header.implicitHeight, state.implicitHeight)

      PanelSectionHeader {
        id: header
        text: "Notes"
        foreground: root.fg
        fontFamily: root.fontFamily
      }

      Text {
        id: state
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.notesEmpty ? "empty" : "click to edit"
        color: Util.alpha(root.fg, 0.45)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    BorderSurface {
      id: previewBox
      width: parent.width
      height: Style.space(58)
      color: Style.controlFill(false, previewHover.hovered, root.fg, root.accent)
      borderSpec: Border.controlSpec(previewHover.hovered ? "hover-cursor" : "normal", root.fg, root.accent)
      radius: Style.cornerRadius

      Text {
        anchors.fill: parent
        anchors.margins: Style.spacing.controlPaddingX
        text: root.notesPreview
        color: root.notesEmpty ? Util.alpha(root.fg, 0.35) : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
        elide: Text.ElideRight
        maximumLineCount: 3
        verticalAlignment: Text.AlignTop
      }

      HoverHandler { id: previewHover }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openEditor()
      }
    }

    Button {
      iconText: "󰷈"
      text: "Write a note"
      foreground: root.fg
      accent: root.accent
      bordered: true
      onClicked: root.openEditor()
    }
  }

  // ------------------------------------------------------------------ editor

  PanelWindow {
    id: editor
    visible: root.editorOpen
    screen: root.screen
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "pomodoro-notes"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.editorOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }

    onVisibleChanged: {
      if (!visible) return
      // Land in the editor once the compositor has mapped this surface.
      Qt.callLater(function() { if (editor.visible) editorText.forceActiveFocus() })
    }

    // Dim the desktop and dismiss on a click outside the card.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.35)

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: root.closeEditor()
      }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Math.max(Style.space(320), parent.width - Style.space(96)), Style.space(560))
      height: Math.min(parent.height - Style.space(96),
                       card.contentTopInset + editorColumn.implicitHeight + card.contentBottomInset)
      color: Color.popups.background
      borderSpec: Border.controlSpec("focus", root.fg, root.accent)
      padding: Style.spacing.popupPadding
      radius: Style.cornerRadius

      // Swallow clicks on the card so only clicks outside dismiss the editor.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
      }

      Column {
        id: editorColumn
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.space(10)

        Item {
          width: parent.width
          height: Math.max(editorTitle.implicitHeight, editorState.implicitHeight)

          PanelSectionHeader {
            id: editorTitle
            text: "Notes"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Text {
            id: editorState
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.notesDirty ? "saving…" : "saved"
            color: Util.alpha(root.fg, 0.45)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        ScrollView {
          id: editorScroll
          width: parent.width
          height: Style.space(240)
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
          ScrollBar.vertical.policy: ScrollBar.AsNeeded

          TextArea {
            id: editorText
            width: editorScroll.availableWidth
            placeholderText: "Write anything — it is saved to a plain markdown file"
            placeholderTextColor: Util.alpha(root.fg, 0.35)
            color: root.fg
            selectionColor: Style.selectionFillFor(root.fg, root.accent)
            selectedTextColor: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            leftPadding: Style.spacing.controlPaddingX + Style.space(2)
            rightPadding: Style.spacing.controlPaddingX + Style.space(2)
            topPadding: Style.spacing.inputPaddingY
            bottomPadding: Style.spacing.inputPaddingY

            background: BorderSurface {
              color: Style.controlFill(editorText.activeFocus, editorText.hovered, root.fg, root.accent)
              borderSpec: Border.controlSpec(editorText.activeFocus ? "focus" : (editorText.hovered ? "hover-cursor" : "normal"), root.fg, root.accent)
              radius: Style.cornerRadius
            }

            onTextChanged: {
              if (root.notesAdopting) return
              root.notesDirty = true
              notesSaveTimer.restart()
            }
            onActiveFocusChanged: if (!activeFocus && root.notesDirty) root.notesSave()
            Keys.onEscapePressed: function(event) { root.closeEditor(); event.accepted = true }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: Math.max(0, parent.width - doneButton.width - parent.spacing)
            anchors.verticalCenter: parent.verticalCenter
            text: "Esc closes · saves as you type · " + root.notesPath
            color: Util.alpha(root.fg, 0.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          Button {
            id: doneButton
            text: "Done"
            foreground: root.fg
            accent: root.accent
            bordered: true
            onClicked: root.closeEditor()
          }
        }
      }
    }

    // Esc also works when the editor itself does not hold focus.
    Item {
      anchors.fill: parent
      focus: editor.visible
      Keys.onEscapePressed: function(event) { root.closeEditor(); event.accepted = true }
    }
  }
}
