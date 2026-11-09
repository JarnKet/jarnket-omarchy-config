#!/usr/bin/env python3
"""Build "Geist Lao": Geist plus Noto Sans Lao, for the Herdr app's UI font.

make-jbm-lao.py fixed Lao in herdr-app's terminals. Mods (chat views, sidebars,
dialogs) draw with the UI font instead, Geist by default, which has no Lao.
Lao there falls back to Noto Sans Lao and meets the same GPUI bug: the Linux
text system (gpui-pre-wgpu cosmic_text_system.rs) places each glyph at
cosmic-text's pen x and drops x_offset/y_offset, so GPOS never moves a mark.
Vowels and tone marks (ິ ີ ່ ້ ...) land beside their consonant instead of on it.

Same cure, proportional this time: every consonant+marks cluster HarfBuzz
produces with Noto Sans Lao becomes one composite glyph with the marks already
where GPOS puts them, swapped in by a last GSUB ligature (GSUB does run). A
cluster's width is its whole shaped advance (ຳ has width of its own).

Latin, digits and punctuation stay Geist's, with Geist's line metrics, so the
UI looks the same; tall Lao stacks draw into the line spacing.

Needs uharfbuzz and fonttools, from the venv make-jbm-lao.py uses:

  py=~/.cache/lao-term/venv/bin/python
  geist=<geist-font release>/Geist/ttf          # github.com/vercel/geist-font, OFL
  out=~/.config/herdr-app/fonts                 # only herdr-app loads fonts from here
  for w in Regular:Regular Medium:Medium SemiBold:Medium Bold:Bold; do
    $py make-ui-lao.py $geist/Geist-${w%%:*}.ttf /usr/share/fonts/noto/NotoSansLao-${w##*:}.ttf \
        $out/GeistLao-${w%%:*}.ttf ${w%%:*}
  done

then "ui_font": "Geist Lao" in ~/.config/herdr-app/settings.json. Noto Sans
Lao has no SemiBold, so SemiBold takes its Medium.

Keep it out of ~/.local/share/fonts, like JetBrains Mono Lao: there
fontconfig would offer it to every app.

License: SIL OFL 1.1 (Geist, Noto Sans Lao), see OFL.txt.
"""
import itertools
import os
import sys
import tempfile
import uharfbuzz as hb
from fontTools import subset
from fontTools.merge import Merger, Options
from fontTools.otlLib.builder import buildLigatureSubstSubtable, buildLookup
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import otTables as ot

FAMILY = "Geist Lao"
LAO = list(range(0x0E80, 0x0F00)) + [0x25CC]  # Lao block + dotted circle

TOP = "ັິີຶືົໍ"
BOTTOM = "ຸູ"
TONES = "່້໊໋"
SIGNS = "໌໎"
LO, AM = "ຼ", "ຳ"
LEADING = "ເແໂໃໄ"
# Mark variants can depend on neighbours, so each syllable is shaped between these.
BEFORE = [""] + list(LEADING)
AFTER = [""] + list("າະຽວຍງນມກດບອ") + list(LEADING)


def tails():
    """Mark sequences that can follow a consonant."""
    one = list(TOP + BOTTOM + TONES + SIGNS + LO)
    out = set(one)
    out |= {v + t for v in TOP + BOTTOM for t in TONES}
    out |= {v + s for v in TOP for s in SIGNS}
    out |= {t + AM for t in TONES} | {AM}
    out |= {LO + m for m in TOP + BOTTOM + TONES + AM} | {LO + v + t for v in TOP for t in TONES}
    out |= {LO + t + AM for t in TONES}
    return sorted(out)


def clusters(path, marks):
    """Shape consonant+tail syllables; yield (glyph names, [(name, x, y)], advance)."""
    blob = hb.Blob.from_file_path(path)
    font = hb.Font(hb.Face(blob))
    tt = TTFont(path)
    order, cmap = tt.getGlyphOrder(), tt.getBestCmap()
    bases = [chr(c) for c in cmap if 0x0E81 <= c <= 0x0EAE or c in (0x0EDC, 0x0EDD, 0x0EDE, 0x0EDF, 0x25CC)]
    for before, base, tail, after in itertools.product(BEFORE, bases, tails(), AFTER):
        buf = hb.Buffer()
        buf.add_str(before + base + tail + after)
        buf.guess_segment_properties()
        hb.shape(font, buf, {})
        glyphs = [(order[i.codepoint], p) for i, p in zip(buf.glyph_infos, buf.glyph_positions)]
        # The consonant and the marks after it, up to the next spacing glyph.
        seq, pen = [], 0
        for name, pos in glyphs[len(before):]:
            if seq and name not in marks:
                break
            seq.append((name, pen + pos.x_offset, pos.y_offset))
            pen += pos.x_advance
        if len(seq) > 1:
            yield tuple(n for n, _, _ in seq), seq, pen


def add_cluster_glyphs(font, path):
    """Composite glyph per shaped cluster, swapped in by a last GSUB lookup."""
    gdef = font["GDEF"].table.GlyphClassDef.classDefs
    marks = {g for g, c in gdef.items() if c == 3}
    glyf, hmtx = font["glyf"], font["hmtx"]
    glyphs = font.getGlyphSet()
    order = list(font.getGlyphOrder())
    ligatures, placed = {}, {}
    for names, seq, advance in clusters(path, marks):
        if names in ligatures:
            if placed[names] != seq:
                print(f"note: {names} shaped two ways; keeping the first", file=sys.stderr)
            continue
        name = "lao.cluster%04d" % len(ligatures)
        pen = TTGlyphPen(glyphs)
        for part, x, y in seq:
            pen.addComponent(part, (1, 0, 0, 1, x, y))
        g = pen.glyph()
        order.append(name)
        glyf[name] = g
        g.recalcBounds(glyf)
        hmtx[name] = (advance, getattr(g, "xMin", 0))
        gdef[name] = 1
        ligatures[names] = name
        placed[names] = seq
    font.setGlyphOrder(order)
    # Last lookup, so the font's own substitutions (ccmp, mark variants) run first.
    gsub = font["GSUB"].table
    gsub.LookupList.Lookup.append(buildLookup([buildLigatureSubstSubtable(ligatures)]))
    gsub.LookupList.LookupCount = len(gsub.LookupList.Lookup)
    record = ot.FeatureRecord()
    record.FeatureTag = "rlig"
    record.Feature = ot.Feature()
    record.Feature.LookupListIndex = [len(gsub.LookupList.Lookup) - 1]
    record.Feature.LookupCount = 1
    gsub.FeatureList.FeatureRecord.append(record)
    gsub.FeatureList.FeatureCount = len(gsub.FeatureList.FeatureRecord)
    index = gsub.FeatureList.FeatureCount - 1
    for script in gsub.ScriptList.ScriptRecord:
        systems = [script.Script.DefaultLangSys] + [r.LangSys for r in script.Script.LangSysRecord]
        for system in filter(None, systems):
            system.FeatureIndex.append(index)
            system.FeatureCount = len(system.FeatureIndex)
    return len(ligatures)


def leftover_offsets(path):
    """Clusters that still carry a GPOS offset GPUI would drop."""
    marks = {g for g, c in TTFont(path)["GDEF"].table.GlyphClassDef.classDefs.items() if c == 3}
    return sum(1 for _, seq, _ in clusters(path, marks) if any(x or y for _, x, y in seq[1:]))


def unhinted(font):
    """The merger can't mix hinting programs; GPUI doesn't use them anyway."""
    for tag in ("fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX", "gasp"):
        if tag in font:
            del font[tag]
    for name in font.getGlyphOrder():
        g = font["glyf"][name]
        if hasattr(g, "program"):
            g.program.fromBytecode(b"")
    return font


latin_path, lao_path, out_path, style = sys.argv[1:5]

with tempfile.TemporaryDirectory() as tmp:
    lao = TTFont(lao_path)
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.glyph_names = True
    opts.hinting = False
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=LAO)
    sub.subset(lao)
    lao_cut = os.path.join(tmp, "lao.ttf")
    unhinted(lao).save(lao_cut)
    lao = TTFont(lao_cut)
    added = add_cluster_glyphs(lao, lao_cut)
    lao.save(lao_cut)
    left = leftover_offsets(lao_cut)

    latin = unhinted(TTFont(latin_path))
    metrics = {
        "hhea": {k: getattr(latin["hhea"], k) for k in ("ascent", "descent", "lineGap")},
        "OS/2": {k: getattr(latin["OS/2"], k) for k in (
            "sTypoAscender", "sTypoDescender", "sTypoLineGap", "usWinAscent", "usWinDescent", "usWeightClass")},
    }
    latin_cut = os.path.join(tmp, "latin.ttf")
    latin.save(latin_cut)

    font = Merger(options=Options(drop_tables=["vhea", "vmtx"])).merge([latin_cut, lao_cut])

for table, values in metrics.items():
    for k, v in values.items():
        setattr(font[table], k, v)
names = font["name"]
for rec in list(names.names):
    if rec.nameID in (1, 2, 3, 4, 6, 16, 17, 21, 22):
        names.removeNames(nameID=rec.nameID)
ribbi = style in ("Regular", "Bold")
ps = FAMILY.replace(" ", "") + "-" + style
entries = [(1, FAMILY if ribbi else f"{FAMILY} {style}"), (2, style if ribbi else "Regular"),
           (3, ps + ";local"), (4, f"{FAMILY} {style}"), (6, ps), (16, FAMILY), (17, style)]
for nid, text in entries:
    names.setName(text, nid, 3, 1, 0x409)
    names.setName(text, nid, 1, 0, 0)
font["OS/2"].fsSelection = (font["OS/2"].fsSelection & ~0b1100001) | (0b100000 if style == "Bold" else 0b1000000 if style == "Regular" else 0)
font["head"].macStyle = 1 if style == "Bold" else 0
font.save(out_path)
cmap = font.getBestCmap()
print(f"{out_path}: {len(font.getGlyphOrder())} glyphs, weight {font['OS/2'].usWeightClass}, "
      f"m={'m' if ord('m') in cmap else 'MISSING'}, "
      f"Lao={sum(cp in cmap for cp in LAO)}/{len(LAO)}, "
      f"{added} cluster glyphs, {left} clusters still offset")
