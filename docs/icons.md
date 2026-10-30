# Striked icon reference

`assets/icons/` holds the Striked-owned SVG icons. All files use a 24×24 viewBox, a 1.75 px stroke, butt caps, miter joins, and `currentColor`. Routes stay unfilled. Nodes carry the fill.

"Diamond" means endpoint, entity, or target. "Square" means system, container, device, or junction. A mixed icon uses each node for its assigned role. Circles are forbidden. Search alone owns the opposing-corner modifier. Add alone owns the bare `+`. Close alone owns the bare `×`.

A closed outline is drawn only where the container is the meaning: a machine, a bay, a keycap, a control frame. Nothing here is a document, a gear, a magnifier, or a cog.

## Signal variants

`signal/` contains one `hl-<name>-signal.svg` for the forty-three icons of the first family pass. A signal variant keeps only the icon's filled diamond and square nodes. It hides every route, frame, seal, check, triangle, and bracket. Icons without a filled node use one standard centered diamond.

The variant is drawn only inside the icon-glitch event. It is not a static icon state and must not replace the normal asset outside that event. No surface asks for one today.

## Navigation

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| home | House outline, open on the right, with the local endpoint inside it | Diamond target | None | 16 px |
| projects | Project hierarchy entry point; intentionally identical to project | Square system nodes | None | 16 px |
| hosts | Two stacked rack units, one machine each | Square system nodes | Container is the meaning | 16 px |
| shell | Prompt caret with the cursor block inline after it | Square cursor block | None | 16 px |
| tools | A bay of docked slots holding unlike modules | Square and diamond module nodes | Container is the meaning | 16 px |
| inbox | Capture entering its container | Square container node | None | 16 px |
| activity | Change trace | Diamond endpoint | None | 16 px |
| search | Targeted scan endpoint | Diamond target | Opposing corners, targeted scan | 16 px |

## Entities

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| project | One project hierarchy; intentionally identical to projects | Square system nodes | None | 16 px |
| goal | Routes converging on an outcome | Diamond target | None | 20 px |
| task | Action moving toward execution | Diamond entity endpoint | None | 16 px |
| note | Recorded information line | Diamond entity node | None | 16 px |
| event | One event branching into context | Diamond entity node | None | 16 px |
| attachment | Linked entity endpoints | Diamond endpoints | None | 20 px |
| agent | A pet: angular ears, two diamond eyes, an open jaw | Diamond eye nodes | None | 20 px |
| agent-blink | The same pet with the viewer's left eye closed to a bar | Diamond eye node | Blink frame only | 20 px |
| branch | One line of work leaving another | Diamond endpoints | None | 16 px |
| files | A folder: a tabbed outline holding one entry | Square node | Container is the meaning | 16 px |
| image | A picture: a frame holding two ridgelines and a square sun | Square node | Container is the meaning | 16 px |
| diff | What was added over what was removed | None | None | 16 px |

## States

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| done | Route completed at its endpoint | Diamond endpoint | None | 16 px |
| pending | Queued directional route | None | None | 16 px |
| active | Live target emitting on two sides | Diamond target | None | 16 px |
| blocked | Route stopped by a barrier | Diamond endpoints | None | 16 px |
| warning | Universal warning sign | Square system dot | None | 16 px |
| failed | Route terminated by failure | Diamond endpoint | None | 16 px |
| priority | Route raised toward a target | Diamond target | None | 16 px |
| critical | Double-bang warning state | Square system dots | None | 16 px |
| acknowledged | Route received and confirmed | Diamond target | None | 16 px |
| verified | Check proven inside a seal; the closed evidence boundary separates it from done | None | None | 16 px |
| progress-marker | Current goal progress head | Diamond target | None | 16 px |

## Transport

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| message | Packet entering a routed path | Square packet node | None | 16 px |
| channel | Two routed system lanes | Square system nodes | None | 20 px |
| device | Solid device block with two routes per side | Square device node | None | 16 px |
| sync | Two-way exchange between endpoints | Diamond endpoints | None | 20 px |
| relay | Junction routing to two endpoints | Square junction and diamond endpoints | None | 20 px |
| connection | Coupled entity endpoints | Diamond endpoints | None | 16 px |
| vault | Protected system convergence | Square system node | None | 16 px |
| encrypted | Sealed entity | Diamond entity node | None | 16 px |
| ssh-key | A key: diamond bow, shaft, two teeth | None | None | 16 px |

## Controls

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| add | Add a new item | None | Bare `+`, reserved | 16 px |
| close | Close or dismiss | None | Bare `×`, reserved | 16 px |
| back | Move to the previous view | None | None | 16 px |
| forward | Move to the next view | None | None | 16 px |
| more | Open overflow actions | Square action nodes | None | 16 px |
| edit | Tool route touching an editable surface | Square tool-tip node | None | 16 px |
| filter | Restrict a result set | Square system nodes | None | 16 px |
| pin | Pin an entity | Diamond entity node | None | 16 px |
| submit | Send captured input to an endpoint | Diamond endpoint | None | 16 px |
| expand | Expand content | None | None | 16 px |
| collapse | Collapse content | None | None | 16 px |
| checkbox-empty | Unchecked task control | None | Square control frame | 16 px |
| checkbox-checked | Checked task control | None | Square control frame | 16 px |
| arrow-up | Direction, up | None | None | 16 px |
| arrow-down | Direction, down | None | None | 16 px |
| arrow-left | Direction, left | None | None | 16 px |
| arrow-right | Direction, right | None | None | 16 px |
| settings | Two faders set to different values | Square handle nodes | None | 16 px |
| plugins | A part with a keyed tab on its edge, waiting for the socket it fits | None | None | 16 px |
| check | Done: a bare tick | None | None | 16 px |
| pause | Hold what is running: two upright bars | None | None | 16 px |
| resume | Carry on from a hold: an open play triangle | None | None | 16 px |
| minimize | Fold a window down to its bar: one floor rule | None | None | 16 px |

## The diff

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| stage | A change routed down into the index: a node landed in an open tray | Square change node | None | 16 px |
| unstage | A change routed up out of the index: the tray left empty | None | None | 16 px |
| discard | A change struck off its route | Diamond change node | None | 16 px |
| wrap | A line too long for the row, routed back to the margin | Square line-start node | None | 16 px |
| split | The two sides read beside each other | None | Container is the meaning | 16 px |
| workspaces | Home tiled into cards: a tall tile beside two stacked ones | Square card node | Container is the meaning | 16 px |
| viewed | Lines read through to the end and ticked | None | None | 16 px |
| log | A file's history: commits down one route, each with its entry | Diamond commit nodes | None | 16 px |

## The screen surface

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| keyboard | The soft keyboard: a panel of key rules over a spacebar | None | Container is the meaning | 16 px |
| keys | The modifier strip: one keycap carrying a caret | None | Container is the meaning | 20 px |
| super | The super key: a centre cap with four corner tabs | None | None | 16 px |
| crop | Two overlapping corner rules marking a region | None | None | 16 px |
| pip | A small window docked inside a larger one | Square window node | None | 20 px |
| voice | Speech as a level trace: five bars, the tallest in the centre | None | None | 16 px |
| screens | A landscape frame left open where a portrait frame cuts through it: one desktop, one device | Square device node | Container is the meaning | 20 px |
| monitor | One desktop: a landscape screen on a stand | None | Container is the meaning | 16 px |
| phone | One device: a portrait frame with its home key | Square key node | Container is the meaning | 16 px |

## Host systems

The vendor marks below and the tmux mark under Launch targets are the only places the family draws somebody else's sign. They are the vendors' own silhouettes, solid and in `currentColor`, because the reader has to recognise them at a glance and a stroked redraw did not. Nothing else in the family may borrow from them.

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| system-nixos | A NixOS host: the snowflake of six lambdas, solid | None | Vendor mark | 16 px |
| system-darwin | A macOS host: the Apple apple with its bite and leaf, solid | None | Vendor mark | 16 px |
| system-ubuntu | An Ubuntu host: the circle of friends, solid | None | Vendor mark | 16 px |
| system-arch | An Arch Linux host: the Arch peak, solid, without its trademark sign | None | Vendor mark | 16 px |
| system-alpine | An Alpine Linux host: the mountains in a hexagon, solid | None | Vendor mark | 16 px |
| system-server | Any other host, or one not yet probed: a single rack unit with its node and a drive slot | Square system node | Container is the meaning | 16 px |

## Launch targets

The launch picker names what a new pane starts in. tmux is the vendor's own mark, solid, under the same exception as the host systems. herdr was drawn for Striked as a solid trace, and is the one solid glyph the family owns.

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| launch-tmux | Start or join a tmux session: the tmux window with its split and status bar, solid | None | Vendor mark | 16 px |
| launch-herdr | Start or join a herdr session: the herdr mark, solid | None | Striked-owned trace | 16 px |
