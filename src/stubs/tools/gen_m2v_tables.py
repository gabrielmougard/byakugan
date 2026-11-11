"""Writes src/stubs/m2v_tables.h, the Unicode tables of the Model2Vec
tokenizers (src/stubs/m2v_text.c).

BERT (WordPiece models): what Hugging Face's BertNormalizer and
BertPreTokenizer do to each code point is asked of the `tokenizers` library
itself, so the tables match it exactly, whichever Unicode versions its Rust
crates embed (unicode_categories is Unicode 9: newer characters count as
unassigned and are deleted).

SentencePiece (Unigram models): grapheme clusters as the unicode-segmentation
crate sees them (UAX #29, Unicode 16.0), from the UCD files.

    python gen_m2v_tables.py UCD_DIR > ../m2v_tables.h
    (UCD_DIR: GraphemeBreakProperty.txt, emoji-data.txt, DerivedCoreProperties.txt)
"""

import os
import sys
import unicodedata

import tokenizers
from tokenizers import normalizers, pre_tokenizers

MAX = 0x110000
SURROGATES = range(0xD800, 0xE000)


def ranges(cps):
    out = []
    for cp in sorted(cps):
        if out and out[-1][1] == cp - 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return out


def c_ranges(name, rs):
    body = ",\n".join("  {0x%X, 0x%X}" % (lo, hi) for lo, hi in rs)
    return f"static const m2v_range {name}[] = {{\n{body}\n}};\n#define {name.upper()}_N {len(rs)}\n"


def c_string(b):
    return '"' + "".join("\\x%02x" % x for x in b) + '"'


# Hangul syllables decompose by arithmetic (Unicode 3.12), done in C instead
# of 11,172 table entries.
HANGUL_FIRST, HANGUL_LAST = 0xAC00, 0xD7A3


def hangul_nfd(cp):
    s = cp - HANGUL_FIRST
    out = chr(0x1100 + s // 588) + chr(0x1161 + (s % 588) // 28)
    return out + (chr(0x11A7 + s % 28) if s % 28 else "")


def bert_tables():
    norm = normalizers.BertNormalizer(clean_text=True, handle_chinese_chars=True, strip_accents=True, lowercase=True)
    pre = pre_tokenizers.BertPreTokenizer()
    drop, space, cjk, mapped = [], [], [], []
    punct, white = [], []
    for cp in range(0x80, MAX):
        if cp in SURROGATES:
            continue
        c = chr(cp)
        out = norm.normalize_str(c)
        if out == "":
            drop.append(cp)
        elif out == " ":
            space.append(cp)
        elif out == " " + c + " ":
            cjk.append(cp)
        elif HANGUL_FIRST <= cp <= HANGUL_LAST:
            if out != hangul_nfd(cp):
                raise SystemExit(f"U+{cp:04X}: Hangul is not plain NFD")
        elif out != c:
            mapped.append((cp, out.encode("utf-8")))
        words = [w for w, _ in pre.pre_tokenize_str("a" + c + "b")]
        if words == ["a", c, "b"]:
            punct.append(cp)
        elif words == ["a", "b"]:
            white.append(cp)
        elif words != ["a" + c + "b"]:
            raise SystemExit(f"U+{cp:04X}: unexpected pre-tokenization {words}")
    blob, entries = b"", []
    for cp, out in mapped:
        entries.append((cp, len(blob), len(out)))
        blob += out
    # Survivors of NFD + accent stripping that canonical ordering can move.
    ccc = [(cp, unicodedata.combining(chr(cp))) for cp in range(MAX)
           if cp not in SURROGATES and unicodedata.combining(chr(cp)) and unicodedata.category(chr(cp)) != "Mn"]
    s = "/* BERT: BertNormalizer(clean_text, handle_chinese_chars, strip_accents,\n   lowercase) and BertPreTokenizer, per code point at or above 0x80. */\n"
    s += c_ranges("m2v_bert_drop", ranges(drop))
    s += c_ranges("m2v_bert_space", ranges(space))
    s += c_ranges("m2v_bert_cjk", ranges(cjk))
    s += "static const m2v_map m2v_bert_map[] = {\n" + ",\n".join(
        "  {0x%X, %d, %d}" % e for e in entries) + "\n};\n#define M2V_BERT_MAP_N %d\n" % len(entries)
    s += "static const char m2v_bert_map_str[] =\n" + "\n".join(
        "  " + c_string(blob[i:i + 64]) for i in range(0, len(blob), 64)) + ";\n"
    s += c_ranges("m2v_bert_punct", ranges(punct))
    s += c_ranges("m2v_bert_white", ranges(white))
    s += "static const m2v_ccc m2v_ccc_table[] = {\n" + ",\n".join(
        "  {0x%X, %d}" % e for e in ccc) + "\n};\n#define M2V_CCC_TABLE_N %d\n" % len(ccc)
    return s


GB = ["Other", "CR", "LF", "Control", "Extend", "ZWJ", "Regional_Indicator", "Prepend", "SpacingMark",
      "L", "V", "T", "LV", "LVT"]


def ucd(path, field_ok):
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        cols = [c.strip() for c in line.split(";")]
        value = field_ok(cols)
        if value is None:
            continue
        a, _, b = cols[0].partition("..")
        for cp in range(int(a, 16), int(b or a, 16) + 1):
            out[cp] = value
    return out


def grapheme_tables(d):
    gb = ucd(os.path.join(d, "GraphemeBreakProperty.txt"), lambda c: c[1])
    pict = ucd(os.path.join(d, "emoji-data.txt"), lambda c: True if c[1] == "Extended_Pictographic" else None)
    incb = ucd(os.path.join(d, "DerivedCoreProperties.txt"),
               lambda c: c[2] if len(c) > 2 and c[1] == "InCB" else None)
    rows, prev = [], None
    for cp in range(MAX):
        v = GB.index(gb.get(cp, "Other"))
        if v and prev and prev[2] == v and prev[1] == cp - 1:
            prev[1] = cp
        elif v:
            prev = [cp, cp, v]
            rows.append(prev)
    s = "/* Graphemes: UAX #29 properties, Unicode 16.0.0. */\nenum { " + ", ".join(
        f"GB_{n.upper()}" for n in GB) + " };\n"
    s += "static const m2v_gb m2v_gb_table[] = {\n" + ",\n".join(
        "  {0x%X, 0x%X, %d}" % tuple(r) for r in rows) + "\n};\n#define M2V_GB_TABLE_N %d\n" % len(rows)
    s += c_ranges("m2v_extpict", ranges(pict))
    for kind in ("Consonant", "Extend", "Linker"):
        s += c_ranges("m2v_incb_" + kind.lower(), ranges(cp for cp, v in incb.items() if v == kind))
    return s


if __name__ == "__main__":
    print(f"/* Generated by src/stubs/tools/gen_m2v_tables.py (tokenizers {tokenizers.__version__},\n"
          "   Unicode 16.0.0 grapheme data). Do not edit. */\n")
    print("typedef struct { uint32_t lo, hi; } m2v_range;")
    print("typedef struct { uint32_t cp; uint32_t off; uint32_t len; } m2v_map;")
    print("typedef struct { uint32_t cp; uint8_t ccc; } m2v_ccc;")
    print("typedef struct { uint32_t lo, hi; uint8_t gb; } m2v_gb;\n")
    print(bert_tables())
    print(grapheme_tables(sys.argv[1]))
