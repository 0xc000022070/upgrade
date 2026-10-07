# SSH connection incident: typed SEND probe

Date: 2026-10-07

## Constraint

Treat an SSH connection as durable state, never as an expendable resource. A background probe must not open, close, replace, or retry a connection. It may open a short-lived channel on a connection that already exists. If that connection is unavailable or the channel fails, the probe must stop and the UI must omit its suggestion. Connection lifecycle changes require an explicit, reviewed path; a command failure alone is not grounds to discard the connection.

## Incident

The first typed SEND implementation called `ShellConnection.exec()` to identify the foreground agent. On plain SSH, `exec()` opened another channel on the current connection. On Mosh and Engine, `exec()` went through `_withHost()`: a missing control connection caused a redial, and any command error caused the current control connection to be closed and redialed. A probe timeout could therefore replace an SSH connection. This violated the constraint above.

## Correction

Typed SEND now uses foreground metadata from the Engine's own PTY when the Engine provides it. That metadata travels on the existing terminal stream and opens no SSH channel. A mapped Herdr pane uses a recent, successful pane snapshot to show SEND, then checks the live agent list on tap through `execOnExistingHost()`. Plain SSH, Mosh, and older Engines use the same existing-host method for foreground probes. Each transport uses its current SSH host directly, without `_withHost()` or `_currentHost()`. A missing control host returns no result. A failed or timed-out probe does not drop or redial the host. Its deadline includes channel opening; if a channel opens after that deadline, it is closed. Tests cover missing hosts, command failures, and a stalled channel open without a new dial. These checks may open an exec channel on the existing SSH connection, never another SSH connection.

The review also found a delayed SEND race, unnecessary overlapping process scans, and possible agent matches from inactive nested multiplexer panes. Input revision checks, serialized scans, and foreground group root matching address those cases. Helper children in an agent's process group do not suppress its match; multiple roots still leave the agent unknown.

## Follow-up

This correction applies to the typed SEND probe. Other calls to `ShellConnection.exec()` still use the existing transport behavior. Audit those call sites and `_withHost()` against this constraint before claiming it holds throughout Upgrade. Do not treat a successful typed SEND test as proof that every SSH path preserves its connection.

### Existing `exec()` call sites

On Mosh and Engine, `exec()` uses `_withHost()`. It dials if the control host is absent. If a command throws, it closes that host, dials another, and retries the command. Plain SSH opens another channel on its existing connection. The list below records call sites; it does not claim they are safe to retry.

| Call site | Command | Concern |
| --- | --- | --- |
| `ShellSessions.cwdFromHost()` | Read shell cwd or Herdr panes | Background read can replace the control connection; pane lookup has no deadline. |
| `ShellSessions.repositoryFromHost()` | Read Git repository root | Background read can replace the control connection. |
| `probeSystem()` in `host_system.dart` | Read OS identity | Background read; its ten-second timeout can trigger a redial. |
| `probeClipboard()` in `host_clipboard.dart` | Detect clipboard backend | Background read can trigger a redial. |
| `ShellSessions._mark()` | Register terminal for pinentry | Automatic write may run twice after an ambiguous failure. |
| `ShellSessions._askHost()` | Poll pinentry request | Repeated background read can repeatedly redial. |
| `ShellSessions.answerPin()` | Write pinentry answer | A retry can repeat an answer whose first write already reached the host. |
| `pasteImage()` in `clip_paste.dart` | Upload image, then set host clipboard | Either write can be retried after an ambiguous failure. |
| Mosh and Engine `terminateRemote()` | Stop remote session and clean up | Explicit lifecycle operation, but generic retry can repeat a stop or cleanup command. |
| Mosh and Engine `remoteDirectory()` | Read tmux directory | Read can trigger a redial. |

The transport startup commands run before a shell connection is returned and are a separate case. Connection recovery and write retries need operation-specific decisions; `_withHost()` cannot tell whether a command ran before it failed.
