# What is known

One case per entry, in the shape a test wants. Each is either already pinned by
a test, or open — true and unpinned — or unknown, meaning nobody has looked.

This package ships no tests of its own. Everything pinned today is a widget
test in dazzle's `test/`, driving `TerminalView` on the shell route.

---

## scroll forwarding

**a drag scrolls the buffer when nothing asked for the mouse**
- given  a terminal with no mouse reporting on
- when   one finger drags over it
- then   the terminal's own scrollable moves and the buffer travels
- status pinned - shell_terminal_test.dart

**a drag becomes wheel reports when an application asked for the mouse**
- given  a terminal with mouse reporting on
- when   one finger drags over it
- then   the view stays frozen and each line of travel is a wheel report on
         the wire
- status pinned - shell_terminal_test.dart

**the forwarding path is one listener and nothing else**
- given  the overlaid scrollable that carries the wheel
- when   its position has no listener on it
- then   the drag is silent, with nothing on screen saying so
- status open

**the listener follows the position across a rebuild**
- given  a terminal with mouse reporting on
- when   the theme over it changes, or the device pixel ratio does
- then   a drag still emits wheel reports
- status pinned - shell_terminal_test.dart

**the keyboard changes nothing**
- given  a terminal with mouse reporting on
- when   the soft keyboard opens
- then   the position object is the same one and the reports are identical
- status open

**a mode swap under a finger waits for the lift**
- given  a drag in progress
- when   the application turns reporting on mid-stroke
- then   the drag finishes on the scrollable it started on, and the swap
         lands when the last finger lifts
- status pinned - shell_terminal_test.dart

**a pane over mosh keeps taps and scrolls remote**
- given  a tab attached to a herdr pane
- when   a finger taps or drags
- then   both go to the far end as mouse input
- status pinned - shell_terminal_test.dart

**a pinch while reporting is on**
- given  a terminal with mouse reporting on
- when   two fingers spread or close
- then   ?
- status unknown

**wheel report rows under a non-zero view padding**
- given  a terminal drawn below other chrome
- when   a drag forwards a wheel report
- then   the row in the report should be the cell row, not one shifted by
         what is drawn above
- status unknown

---

## modes and who owns them

**modes belong to the program, not the connection**
- given  a session whose terminal outlives its link by design
- when   the link drops under a full-screen application
- then   nothing clears the modes that application set
- status open

**a new shell gets a terminal in a new terminal's state**
- given  a session left on the alternate screen with reporting on
- when   it reconnects as a new shell
- then   reporting is off in all three modes, the encoding is off, bracketed
         paste is off, and the prompt lands over the old scrollback
- status pinned - shell_sessions_test.dart (uncommitted)

**a pane is exempt from the reset**
- given  a tab attached to a herdr pane
- when   it reattaches after a drop
- then   the modes its application set are still in force
- status pinned - shell_sessions_test.dart (uncommitted)

**the alternate screen is left only when it is occupied**
- given  a terminal on the normal screen
- when   a reconnect resets its modes
- then   no `?1049l` is emitted, because it would restore a cursor that was
         never saved
- status pinned - shell_sessions_test.dart (uncommitted)

**a terminal still reporting reads as dead to the touch**
- given  reporting left on after the program that set it is gone
- when   a finger drags or taps
- then   nothing scrolls and nothing under the finger answers, because the
         shell that came back discards every report
- status open

**`?1003` any-motion reporting**
- given  an application that asks for `?1003` rather than `?1002`
- when   a finger drags
- then   it should behave as `?1002` does
- status unknown

**bracketed paste**
- given  `?2004` set by a program
- when   anything at all
- then   ?
- status unknown, beyond being cleared on reconnect

**mode state across a resize**
- given  a terminal holding modes
- when   the view resizes or reflows
- then   ?
- status unknown

---

## coordinates under a moving buffer

**a pixel is worth only the scroll offset it landed on**
- given  a finger held on a line
- when   the shell prints and the line moves before the press is reported
- then   the selection takes the cell the finger landed on, not the cell now
         under it
- status pinned - shell_terminal_test.dart

**a line that leaves the scrollback stops the press**
- given  a live press on a line
- when   that line is evicted from the scrollback
- then   the press stops moving rather than chasing a row that is gone, and
         a selection grip keeps its end the same way
- status pinned - shell_terminal_test.dart

**a second finger does not move the first one's anchor**
- given  a press in progress
- when   a second finger lands
- then   the anchor stays where the first finger put it
- status pinned - shell_terminal_test.dart

**the touch offset is local, not global**
- given  a terminal with chrome drawn above it
- when   a cell offset is resolved from a touch
- then   only the view's padding is subtracted
- status open

---

## what a press takes

**a press takes the token under it**
- given  a finger on a line of text
- when   it long-presses
- then   the run of non-blank cells around it is selected, across a soft
         wrap, less punctuation the run only happens to end in
- status pinned - terminal_token_test.dart

**a gap still selects**
- given  a finger on whitespace
- when   it presses, and then drags
- then   the point stands for its own cell and the drag follows the finger
- status pinned - shell_terminal_test.dart

**a tap is not a tap until it lifts**
- given  a finger down on a terminal under an application
- when   the press goes on to be a long press or a scroll
- then   no click reaches the application and the selection is not dropped
- status pinned - shell_terminal_test.dart

**a full-screen application still gives up a line**
- given  a terminal showing a full-screen application
- when   a finger long-presses
- then   the line under it is selectable
- status pinned - shell_terminal_test.dart

**a wide glyph does not slide the columns after it**
- given  a line containing a glyph wider than one cell
- when   a cell offset is resolved past it
- then   the column is the cell column
- status pinned - terminal_token_test.dart

---

## buffer and reflow

**a trim moves the absolute start with it**
- given  a scrollback at its limit
- when   lines are dropped from the front
- then   the absolute start index moves down by the same count, so line
         indices after the trim are still right
- status pinned - terminal_buffer_test.dart

**a wholesale replacement restarts at slot zero**
- given  a buffer being replaced outright
- when   the replacement is written
- then   it goes through the new start, not the one the old contents ended on
- status pinned - terminal_buffer_test.dart

**a shrink on the alternate screen leaves rows where they are**
- status pinned - terminal_buffer_test.dart

**a reflow after the scrollback has wrapped keeps the order**
- status pinned - terminal_buffer_test.dart

**eviction must skip a re-adopted line**
- given  a line re-homed to another index by a reflow
- when   its old slot is overwritten
- then   the line is not detached, because it is still in the list
- status open

---

## keyboard

**a tap does not ask for the keyboard**
- given  the shell route, which passes `keyboardOnTap: false`
- when   a finger taps the terminal
- then   the selection clears and no keyboard comes up; the route raises it
         through an explicit request or the focus node
- status pinned - keyboard_release_test.dart, bottom_inset_test.dart
