# Dazzle icon grammar candidates

This sheet tests structure, not a finished family. The labels identify the intended reading. They do not approve the symbol.

## Shared constraints

- ViewBox: `0 0 24 24`.
- Working grid: 1 px. Primary anchors sit at 4, 8, 12, 16, and 20. Half-unit shifts are allowed only for optical balance.
- Color: one foreground color. The experiments use `#E8E8E3` on `#08090B`.
- Geometry: 45° diagonals and orthogonal routes. Curves are excluded from this pass.
- Alignment: center around x=12 and y=12 unless the concept requires directional weight.
- Optical padding: keep active geometry inside x/y 3–21. Most icons stay inside 4–20.
- Export: strokes remain strokes. Filled markers remain separate shapes. Do not convert these experiments into a shared path until a grammar wins.

## A. Routed stroke

The icon is one schematic route or a small set of connected routes. Meaning comes from interruption, convergence, branching, and direction.

- Stroke: 1.75 px.
- Terminals: butt caps. Exposed ends stop on the grid.
- Corners: hard miters. Use 90° first and 45° only for direction or closure. Miter limit 2.
- Fill: none.
- Density: two route levels maximum. Avoid an outer container unless it carries meaning.
- Optical padding: 3.5 px minimum. Diagonal tips may reach 3 px.
- Min size: 18 px. At 16 px, remove secondary rails and keep one route.

Strength: reads as process and direction. Weakness: entity icons can drift toward unrelated outline symbols.

## B. Signal nodes

Thin routes connect solid terminals, junctions, or state markers. The filled node is semantic, not decoration.

- Stroke: 1.5 px.
- Terminals: butt caps. A route either ends cleanly or enters a node.
- Nodes: 2.5–3 px solid squares or 45° diamonds. Use one node class per icon. Four nodes is the normal limit.
- Corners: hard miters at 45° or 90°. No rounded junctions.
- Fill: routes never fill. Nodes fill with the foreground color. Closed warning or seal shapes stay unfilled.
- Optical padding: 3 px around nodes, 3.5 px around bare strokes.
- Alignment: routes use the 1 px grid. Node centers land on whole coordinates.
- Min size: 16 px when limited to two nodes and one route. Multi-node relay symbols need 20 px.

Strength: gives state and communication concepts a distinct visual mechanism. It also supports active-state color without depending on color.

## C. Open frames

Corner brackets establish a field. The internal mark describes the entity or state. The frame stays broken so the icons do not become generic app tiles.

- Stroke: 1.75 px. A 2 px cut may be tested at 16 px after selection.
- Terminals: butt caps.
- Corners: hard 90° outer corners. Internal marks may use 45° diagonals.
- Fill: none in this sheet. A single solid center marker is allowed in later tests if every family member follows the same rule.
- Frame rule: never draw more than 60% of the perimeter. Keep at least two opposing gaps.
- Optical padding: outer frame sits at x/y 4–20. Internal marks keep 2 px clearance from it.
- Alignment: frames use the 4/9/15/20 anchors. Internal marks use the central 8–16 field.
- Min size: 20 px. At 16 px, the frame competes with the internal mark.

Strength: strong family recognition in navigation. Weakness: repeated frames flatten differences between concepts and consume space.

## Recommendation

Choose B, Signal nodes.

It best fits Dazzle's routing, status, acknowledgement, relay, and connection language. Filled nodes create a clear signature in monochrome and provide a controlled active-state accent later. The grammar also survives at 16 px when each icon keeps one route and no more than two nodes. A is useful but less ownable. C is distinctive as a set, yet too heavy for dense mobile navigation and metadata rows.

## Decision

B, Signal nodes, is the approved base grammar. These rules supersede the candidate notes above.

- ViewBox: `0 0 24 24`.
- Family stroke: 1.75 px at 24 px. Routes use `currentColor`, butt caps, and miter joins.
- Diamond node: endpoint, entity, or target. Use it for goals, the home origin, connection endpoints, and acknowledgement.
- Square node: system, container, device, or relay junction.
- Circle node: forbidden.
- Node selection follows meaning. An icon may contain both classes when it joins a system junction to entity endpoints.
- Fill: nodes only. Routes and closed silhouettes stay unfilled.
- Corners: 45° and 90°. No curves.
- Modifier: top-left and bottom-right corner brackets mean targeted, active, next action, or selected. They modify the glyph and never contain it.
- Modifier use in the initial family: search only. No other icon gets brackets or a frame.
- Goal keeps A06's converging routes with a diamond target node.
- Activity keeps A03's trace with a diamond endpoint node.
- Warning keeps its unfilled triangle. Its bang uses two straight segments and a square dot.
- Blocked keeps B01's broken route and cross barrier. Its endpoint nodes are diamonds under the semantic mapping.
- Search keeps the scan brackets around one diamond target node. It has no cross.
- Acknowledged uses an entering route, a diamond node, and a two-segment check on exit.
- Encrypted keeps the seal silhouette with one diamond node and no interior cross.
- Note uses log rails with one diamond entity node at the left margin.
- Message uses one square packet node with a routed tail entering from the left.
- Project uses a square root node and two square child nodes.
- Optical bounds: most routes stay inside x/y 3–21. Node tips may reach 2–22 when the node is an endpoint.
- Minimum size: 16 px for compact icons and 20 px for multi-route icons, as recorded in `ICONS.md`.
- Cross budget: a bare `+` belongs only to add. A bare `×` belongs only to close. Blocked and failed combine a diagonal cross with a route, so their state meaning survives without labels.
- Home has no modifier. The approved drop plus baseline construction uses a vertical route, one diamond local endpoint, and one short baseline.
- Critical uses a double-bang warning triangle. Warning keeps one bent bang. The pair remains distinct at 16 px.
- Verified uses a check inside the encrypted seal silhouette. Done remains an open check route ending at a diamond node.
- Projects and project intentionally share one glyph. Navigation context and labels carry plurality. A second symbol would imply a false semantic difference.
