from pathlib import Path
import json
from PIL import Image

ROOT = Path(__file__).parents[1]
GRID = ROOT / "sprites" / "mascot"
OUT = ROOT.parents[0] / "assets" / "sprites"
TOKENS = {".": (0, 0, 0, 0), "#": (232, 232, 227, 255), "a": (183, 255, 42, 255)}
TABLE = {"idle": (2, 2, True), "looking": (2, 2, True), "working": (4, 8, True), "success": (4, 6, False), "blocked": (2, 2, True), "alert": (2, 4, True), "sleep": (3, 2, True), "splash": (7, 6, False)}

def base(extra=""):
    g = [["."] * 48 for _ in range(48)]
    def put(x, y, s, c="#"):
        for i, ch in enumerate(s):
            if 0 <= x+i < 48 and 0 <= y < 48 and ch != ".": g[y][x+i] = c if ch == "#" else ch
    put(17, 6, "#######"); put(15, 8, "###########"); put(17, 10, "#######")
    put(18, 12, "######"); put(17, 13, "########")
    put(18, 14, "#..##..#"); put(18, 15, "########")
    put(17, 17, "##..##"); put(17, 18, "########")
    put(15, 20, "##"); put(29, 20, "##"); put(14, 21, "###"); put(29, 21, "###")
    put(13, 22, "###"); put(30, 22, "###"); put(14, 23, "##"); put(30, 23, "##")
    put(18, 21, "##"); put(23, 21, "##"); put(18, 22, "##"); put(23, 22, "##")
    put(18, 24, "########"); put(18, 25, "#..##..#"); put(18, 26, "########")
    put(17, 28, "##"); put(25, 28, "##"); put(16, 29, "###"); put(26, 29, "###")
    put(16, 30, "##"); put(27, 30, "##"); put(17, 31, "##"); put(27, 31, "##")
    put(17, 33, "##"); put(27, 33, "##"); put(16, 35, "###"); put(26, 35, "###")
    put(14, 37, "#####"); put(25, 37, "#####"); put(13, 38, "######"); put(24, 38, "######")
    put(35, 20, "##"); put(36, 21, "##"); put(37, 22, "##"); put(38, 23, "##"); put(39, 24, "##")
    for x in range(14, 34): g[44][x] = "#"
    for (x, y), c in extra:
        if 0 <= x < 48 and 0 <= y < 48: g[y][x] = c
    return ["".join(r) for r in g]

def make_grids():
    if (GRID / "base.txt").exists() and all((GRID / s / "01.txt").exists() for s in TABLE):
        return
    source = (GRID / "base.txt").read_text().splitlines()
    def frame(dx=0, dy=0, edits=()):
        g = [list(r) for r in source]
        if dx or dy:
            n = [["."] * 48 for _ in range(48)]
            for y, row in enumerate(g):
                for x, c in enumerate(row):
                    if 0 <= x + dx < 48 and 0 <= y + dy < 48: n[y + dy][x + dx] = c
            g = n
        for x, y, c in edits:
            if 0 <= x < 48 and 0 <= y < 48: g[y][x] = c
        return ["".join(r) for r in g]
    plans = {
        "idle": [frame(), frame(dy=-1)],
        "looking": [frame(edits=[(27, 13, "#"), (28, 13, "#"), (29, 13, "#"), (30, 13, "#")]), frame(dy=-1, edits=[(27, 12, "#"), (28, 12, "#"), (29, 12, "#"), (30, 12, "#")])],
        "working": [frame(), frame(dx=2, edits=[(8, 30, "#"), (9, 30, "#"), (6, 32, "#")]), frame(dx=2, edits=[(30, 30, "#"), (31, 30, "#"), (7, 32, "#")]), frame(edits=[(8, 30, "#"), (9, 30, "#")])],
        "success": [frame(edits=[(34, 12, "a")]), frame(edits=[(35, 11, "a"), (36, 10, "a")]), frame(edits=[(35, 10, "a"), (37, 9, "a"), (39, 11, "a")]), frame(edits=[(34, 9, "a"), (37, 8, "a"), (40, 10, "a"), (42, 12, "a")])],
        "blocked": [frame(edits=[(35, 14, "a"), (35, 15, "a"), (35, 16, "a"), (35, 17, "a"), (35, 19, "a")]), frame()],
        "alert": [frame(edits=[(35, 14, "a"), (35, 15, "a"), (35, 16, "a"), (35, 17, "a"), (35, 19, "a")]), frame(edits=[(34, 14, "a"), (34, 15, "a"), (34, 16, "a"), (34, 17, "a"), (34, 19, "a")])],
        "sleep": [frame(edits=[(19, 14, "#"), (20, 14, "#"), (26, 14, "#"), (27, 14, "#"), (35, 10, "a")]), frame(edits=[(19, 14, "#"), (20, 14, "#"), (26, 14, "#"), (27, 14, "#"), (34, 8, "a"), (35, 8, "a")]), frame(edits=[(19, 14, "#"), (20, 14, "#"), (26, 14, "#"), (27, 14, "#"), (33, 6, "a"), (34, 6, "a")])],
        "splash": [frame(), frame(edits=[(12, 12, "a"), (16, 9, "a"), (22, 7, "a"), (28, 9, "a"), (33, 12, "a"), (36, 15, "a")]), frame(), frame(dx=1), frame(dx=1, dy=0), frame(), frame()]
    }
    for state, frames in plans.items():
        d = GRID / state; d.mkdir(parents=True, exist_ok=True)
        for i, rows in enumerate(frames, 1): (d / f"{i:02}.txt").write_text("\n".join(rows) + "\n")

def build():
    make_grids(); OUT.mkdir(parents=True, exist_ok=True); manifest = {"cell": 48, "states": {}}
    for state, (count, fps, loop) in TABLE.items():
        frames = []
        for i in range(1, count + 1):
            rows = (GRID / state / f"{i:02}.txt").read_text().splitlines()
            if len(rows) != 48 or any(len(r) != 48 or any(c not in TOKENS for c in r) for r in rows): raise ValueError(state)
            frames.append(rows)
        sheet = Image.new("RGBA", (48 * count, 48))
        for i, rows in enumerate(frames):
            for y, row in enumerate(rows):
                for x, ch in enumerate(row): sheet.putpixel((i * 48 + x, y), TOKENS[ch])
        sheet.save(OUT / f"mascot-{state}.png"); manifest["states"][state] = {"frames": count, "fps": fps, "loop": loop}
    (OUT / "mascot.json").write_text(json.dumps(manifest, separators=(",", ":")))

if __name__ == "__main__":
    import sys
    if "--diff" in sys.argv:
        b = (GRID / "base.txt").read_text().splitlines()
        for state, (n, _, _) in TABLE.items():
            for i in range(1, n + 1):
                rows = (GRID / state / f"{i:02}.txt").read_text().splitlines()
                print(f"{state}/{i:02}: {sum(ch1 != ch2 for row1, row2 in zip(b, rows) for ch1, ch2 in zip(row1, row2))}")
    else:
        build()
