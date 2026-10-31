#!/usr/bin/env python3
"""Build "JetBrains Mono Lao": JetBrains Mono (Nerd Font) plus Lao Term's Lao.

For GPUI terminals (the Herdr app, herdr-app; also Herdr UI), which take one
font family and draw Lao wrong in two ways:

1. Without Lao of its own the terminal borrows Noto Sans Lao, whose narrow
   letters break the cell grid ("ເ ຮັດ", "ພາ ສາ"). Lao Term's letters are all
   600 units wide, like JetBrains Mono, so merged into one family they fit.

2. GPUI's Linux text system (gpui-pre-wgpu cosmic_text_system.rs) places each
   glyph at cosmic-text's pen x and drops x_offset/y_offset, so GPOS never
   moves a mark: ່ ້ ິ land after their consonant instead of on it, and stacked
   marks collide. So each consonant+marks cluster the shaper produces becomes
   one composite glyph with the marks already where GPOS puts them, and a
   GSUB ligature (GSUB does run) swaps it in. Nothing is left to offset.

The clusters come from shaping every consonant with Lao's vowel, tone and
subscript combinations through HarfBuzz, so only sequences that occur get a
glyph. A cluster the list misses keeps its marks (drawn after the letter).

Lao Term is cut down to its Lao block, so every Latin glyph and icon comes
from JetBrains Mono. Line metrics stay JetBrains Mono's, so rows keep their
height; tall Lao stacks draw into the line spacing, as in kitty.

Needs uharfbuzz, from a venv kept out of this (synced) folder:

  py=~/.cache/lao-term/venv/bin/python   # python3 -m venv ~/.cache/lao-term/venv; $py -m pip install uharfbuzz fonttools
  out=~/.config/herdr-app/fonts                  # only herdr-app loads fonts from here
  $py make-jbm-lao.py /usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf \
      ~/.local/share/fonts/LaoTerm-Regular.ttf $out/JetBrainsMonoLao-Regular.ttf Regular
  $py make-jbm-lao.py /usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf \
      ~/.local/share/fonts/LaoTerm-Bold.ttf $out/JetBrainsMonoLao-Bold.ttf Bold

Keep it out of ~/.local/share/fonts: there fontconfig would offer it to every
app as a Lao fallback, the regression 50-lao-term-kitty-only.conf undoes.

License: SIL OFL 1.1 (JetBrains Mono, Noto Sans Lao), see OFL.txt.
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

FAMILY = "JetBrains Mono Lao"
LAO = list(range(0x0E80, 0x0F00)) + [0x25CC]  # Lao block + dotted circle

TOP = "ັິີຶືົໍ"  # ັ ິ ີ ຶ ື ົ ໍ
BOTTOM = "ຸູ"                              # ຸ ູ
TONES = "່້໊໋"                   # ່ ້ ໊ ໋
SIGNS = "໌໎"                               # ໌ and yamakkan
LO, AM = "ຼ", "ຳ"                          # subscript ຼ, ຳ
LEADING = "ເແໂໃໄ"           # ເ ແ ໂ ໃ ໄ
# Mark variants depend on neighbours (".center" after a leading vowel), so
# each syllable is shaped between these.
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
    """Shape consonant+tail syllables; yield (glyph names, [(name, x, y)])."""
    blob = hb.Blob.from_file_path(path)
    font = hb.Font(hb.Face(blob))
    order = TTFont(path).getGlyphOrder()
    cmap = TTFont(path).getBestCmap()
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
            yield tuple(n for n, _, _ in seq), seq


def add_cluster_glyphs(font, path):
    """Composite glyph per shaped cluster, swapped in by a last GSUB lookup."""
    gdef = font["GDEF"].table.GlyphClassDef.classDefs
    marks = {g for g, c in gdef.items() if c == 3}
    glyf, hmtx = font["glyf"], font["hmtx"]
    glyphs = font.getGlyphSet()
    order = list(font.getGlyphOrder())
    ligatures, placed = {}, {}
    for names, seq in clusters(path, marks):
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
        hmtx[name] = (hmtx[seq[0][0]][0], getattr(g, "xMin", 0))
        gdef[name] = 1
        ligatures[names] = name
        placed[names] = seq
    font.setGlyphOrder(order)
    # Last lookup, so Lao Term's own substitutions (ccmp, mark variants) run
    # first and the ligature sees their output.
    gsub = font["GSUB"].table
    lookup = buildLookup([buildLigatureSubstSubtable(ligatures)])
    gsub.LookupList.Lookup.append(lookup)
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
    return sum(1 for _, seq in clusters(path, marks) if any(x or y for _, x, y in seq[1:]))


jbm_path, lao_path, out_path, style = sys.argv[1:5]

with tempfile.TemporaryDirectory() as tmp:
    # Lao only, with its shaping features intact.
    lao = TTFont(lao_path)
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.glyph_names = True
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=LAO)
    sub.subset(lao)
    lao_cut = os.path.join(tmp, "lao.ttf")
    lao.save(lao_cut)
    lao = TTFont(lao_cut)
    added = add_cluster_glyphs(lao, lao_cut)
    lao.save(lao_cut)
    left = leftover_offsets(lao_cut)

    # Neither side keeps TrueType hinting: Lao Term has none, and the
    # merger cannot mix hinted and unhinted programs.
    jbm = TTFont(jbm_path)
    for tag in ("fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX"):
        if tag in jbm:
            del jbm[tag]
    for name in jbm.getGlyphOrder():
        g = jbm["glyf"][name]
        if hasattr(g, "program"):
            g.program.fromBytecode(b"")
    metrics = {
        "hhea": {k: getattr(jbm["hhea"], k) for k in ("ascent", "descent", "lineGap")},
        "OS/2": {k: getattr(jbm["OS/2"], k) for k in (
            "sTypoAscender", "sTypoDescender", "sTypoLineGap", "usWinAscent", "usWinDescent")},
    }
    jbm_cut = os.path.join(tmp, "jbm.ttf")
    jbm.save(jbm_cut)

    font = Merger(options=Options(drop_tables=["vhea", "vmtx"])).merge([jbm_cut, lao_cut])

for table, values in metrics.items():
    for k, v in values.items():
        setattr(font[table], k, v)
font["post"].isFixedPitch = 1
names = font["name"]
for rec in list(names.names):
    if rec.nameID in (1, 2, 3, 4, 6, 16, 17, 21, 22):
        names.removeNames(nameID=rec.nameID)
ps = FAMILY.replace(" ", "") + "-" + style
for nid, text in ((1, FAMILY), (2, style), (3, ps + ";local"), (4, f"{FAMILY} {style}"), (6, ps)):
    names.setName(text, nid, 3, 1, 0x409)
    names.setName(text, nid, 1, 0, 0)
font.save(out_path)
cmap = font.getBestCmap()
print(f"{out_path}: {len(font.getGlyphOrder())} glyphs, "
      f"m={'m' if ord('m') in cmap else 'MISSING'}, "
      f"Lao={sum(cp in cmap for cp in LAO)}/{len(LAO)}, "
      f"{added} cluster glyphs, {left} clusters still offset")
