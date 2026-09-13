# Dazzle production icon reference

This directory contains 43 Dazzle-owned SVG icons. All files use a 24×24 viewBox, a 1.75 px stroke, butt caps, miter joins, and `currentColor`. Routes stay unfilled. Nodes carry the fill.

"Diamond" means endpoint, entity, or target. "Square" means system, container, device, or junction. A mixed icon uses each node for its assigned role. Circles are forbidden. Search alone owns the opposing-corner modifier. Add alone owns the bare `+`.

`hl-home.svg` uses the approved drop plus baseline construction. The vertical route terminates at a diamond local endpoint above a short baseline.

## Signal variants

`signal/` contains one `hl-<name>-signal.svg` for every production icon. A signal variant keeps only the icon's filled diamond and square nodes. It hides every route, frame, seal, check, triangle, and bracket. Icons without a filled node use one standard centered diamond.

The variant appears for one frame of the section 16b icon-glitch event. It is not a static icon state and must not replace the normal asset outside that event.

| Name | Meaning | Node class | Modifier | Min size |
|---|---|---|---|---:|
| home | Local endpoint on a baseline | Diamond target | None | 16 px |
| projects | Project hierarchy entry point; intentionally identical to project | Square system nodes | None | 16 px |
| inbox | Capture entering its container | Square container node | None | 16 px |
| activity | Change trace | Diamond endpoint | None | 16 px |
| search | Targeted scan endpoint | Diamond target | Opposing corners, targeted scan | 16 px |
| project | One project hierarchy; intentionally identical to projects | Square system nodes | None | 16 px |
| goal | Routes converging on an outcome | Diamond target | None | 20 px |
| task | Action moving toward execution | Diamond entity endpoint | None | 16 px |
| note | Recorded information line | Diamond entity node | None | 16 px |
| event | One event branching into context | Diamond entity node | None | 16 px |
| attachment | Linked entity endpoints | Diamond endpoints | None | 20 px |
| done | Route completed at its endpoint | Diamond endpoint | None | 16 px |
| pending | Queued directional route | None | None | 16 px |
| active | Live target emitting on two sides | Diamond target | None | 16 px |
| blocked | Route stopped by a barrier | Diamond endpoints | None | 16 px |
| warning | Universal warning sign | Square system dot | None | 16 px |
| failed | Route terminated by failure | Diamond endpoint | None | 16 px |
| message | Packet entering a routed path | Square packet node | None | 16 px |
| channel | Two routed system lanes | Square system nodes | None | 20 px |
| priority | Route raised toward a target | Diamond target | None | 16 px |
| critical | Double-bang warning state | Square system dots | None | 16 px |
| acknowledged | Route received and confirmed | Diamond target | None | 16 px |
| encrypted | Sealed entity | Diamond entity node | None | 16 px |
| verified | Check proven inside a seal; the closed evidence boundary separates it from done | None | None | 16 px |
| device | Solid device block with two routes per side | Square device node | None | 16 px |
| sync | Two-way exchange between endpoints | Diamond endpoints | None | 20 px |
| relay | Junction routing to two endpoints | Square junction and diamond endpoints | None | 20 px |
| vault | Protected system convergence | Square system node | None | 16 px |
| connection | Coupled entity endpoints | Diamond endpoints | None | 16 px |
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
| progress-marker | Current goal progress head | Diamond target | None | 16 px |
