#!/usr/bin/env python3
"""Build "Lao Term": Noto Sans Lao refitted to a 0.6 em terminal cell.

Kitty draws each character in a fixed cell (JetBrains Mono = 0.6 em). A
glyph wider than the cell is scaled down in BOTH directions, so wide Lao
letters (ໝ ໜ are ~1 em) come out tiny. This font gives every spacing glyph
a 600-unit advance and squeezes wider ink horizontally only, so letters
keep their full height. Leading vowels (ເ ແ ໂ ໃ ໄ) sit at the right of
their cell and trailing vowels (ະ າ ຳ ຽ ໆ ຯ) at the left, so they hug the
consonant instead of leaving a gap. Mark anchors move with their base, and
kerning is switched off.

usage: make-lao-term.py SRC.ttf OUT.ttf STYLE      (STYLE = Regular | Bold)

  cd ~/.local/share/fonts
  make-lao-term.py /usr/share/fonts/noto/NotoSansLao-Regular.ttf LaoTerm-Regular.ttf Regular
  make-lao-term.py /usr/share/fonts/noto/NotoSansLao-Bold.ttf LaoTerm-Bold.ttf Bold
  fc-cache

License: SIL OFL 1.1, see OFL.txt next to this script.
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import ttProgram
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen

CELL, MAX_INK, MARGIN = 600, 560, 20
FAMILY = "Lao Term"
LEADING = set(range(0x0EC0, 0x0EC5))                      # ເ ແ ໂ ໃ ໄ
TRAILING = {0x0EB0, 0x0EB2, 0x0EB3, 0x0EBD, 0x0EC6, 0x0EAF}  # ະ າ ຳ ຽ ໆ ຯ

src_path, out_path, style = sys.argv[1:4]
src = TTFont(src_path)
font = TTFont(src_path)
glyf, hmtx = font["glyf"], font["hmtx"]
src_glyphs = src.getGlyphSet()
classes = font["GDEF"].table.GlyphClassDef.classDefs
codepoint = {}
for cp, name in font.getBestCmap().items():
    codepoint.setdefault(name, cp)

moves = {}  # glyph name -> (scale_x, offset_x)
for name in font.getGlyphOrder():
    adv = hmtx[name][0]
    if classes.get(name) == 3 or adv == 0:  # marks keep their shape and place
        continue
    rec = DecomposingRecordingPen(src_glyphs)
    src_glyphs[name].draw(rec)
    g = src["glyf"][name]
    if not rec.value or g.numberOfContours == 0 and not g.isComposite():
        hmtx[name] = (CELL, 0)
        continue
    g.recalcBounds(src["glyf"])
    x0, x1 = g.xMin, g.xMax
    s = min(1.0, MAX_INK / (x1 - x0))
    w = (x1 - x0) * s
    cp = codepoint.get(name)
    if cp in LEADING:
        new_x0 = CELL - MARGIN - w
    elif cp in TRAILING:
        new_x0 = MARGIN
    else:
        new_x0 = (CELL - w) / 2
    dx = new_x0 - s * x0
    moves[name] = (s, dx)
    pen = TTGlyphPen(None)
    rec.replay(TransformPen(pen, (s, 0, 0, 1, dx, 0)))
    new = pen.glyph()
    new.recalcBounds(glyf)
    glyf[name] = new
    hmtx[name] = (CELL, new.xMin)

# Move base anchors with their glyph (mark-to-base and mark-to-ligature).
def lookups(table):
    for lookup in table.LookupList.Lookup:
        for st in lookup.SubTable:
            yield st.ExtSubTable if lookup.LookupType == 9 else st

def move_anchor(anchor, name):
    if anchor is not None and name in moves:
        s, dx = moves[name]
        anchor.XCoordinate = round(anchor.XCoordinate * s + dx)

gpos = font["GPOS"].table
for st in lookups(gpos):
    if st.LookupType == 4:
        for name, rec in zip(st.BaseCoverage.glyphs, st.BaseArray.BaseRecord):
            for a in rec.BaseAnchor:
                move_anchor(a, name)
    elif st.LookupType == 5:
        for name, lig in zip(st.LigatureCoverage.glyphs, st.LigatureArray.LigatureAttach):
            for comp in lig.ComponentRecord:
                for a in comp.LigatureAnchor:
                    move_anchor(a, name)
for fr in gpos.FeatureList.FeatureRecord:  # monospace: no kerning
    if fr.FeatureTag == "kern":
        fr.Feature.LookupListIndex = []
        fr.Feature.LookupCount = 0

# Hinting no longer matches the outlines; drop it everywhere.
for tag in ("fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX"):
    if tag in font:
        del font[tag]
for name in font.getGlyphOrder():
    g = glyf[name]
    if hasattr(g, "program"):
        g.program = ttProgram.Program()
        g.program.fromBytecode(b"")

font["post"].isFixedPitch = 1
font["OS/2"].panose.bProportion = 9
font["OS/2"].xAvgCharWidth = CELL
font["hhea"].advanceWidthMax = CELL
names = font["name"]
for rec in list(names.names):
    if rec.nameID in (1, 2, 3, 4, 6, 16, 17, 21, 22):
        names.removeNames(nameID=rec.nameID)
ps = FAMILY.replace(" ", "") + "-" + style
for nid, text in ((1, FAMILY), (2, style), (3, ps + ";local"), (4, f"{FAMILY} {style}"), (6, ps)):
    names.setName(text, nid, 3, 1, 0x409)
    names.setName(text, nid, 1, 0, 0)
names.setName("Noto Sans Lao refitted to a 0.6 em terminal cell (local build).", 10, 3, 1, 0x409)
font.save(out_path)
print(f"{out_path}: {len(moves)} glyphs refitted")
