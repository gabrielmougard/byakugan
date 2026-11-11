"""Expected token ids from Hugging Face tokenizers, the fixtures of
src/test/test_m2v.ml (the C tokenizers of src/stubs/m2v_text.c must give the
same ids).

    python m2v_fixtures.py TOKENIZER_JSON OUT_TSV [--all] [HEXFILE...]

Writes set<TAB>text-hex<TAB>comma-separated ids per line. Committed fixtures
hold only synthetic text: the edge cases and 600 random strings. --all adds
3000 random strings and every code point between two letters (1.1M lines),
and each HEXFILE (texts, hex, one per line) a set of its own: that is the
full check run before committing a tokenizer change."""
import random
import sys

from tokenizers import Tokenizer

EDGE = [
    "Hello, world!", "The QUICK brown fox jumps.", "café résumé naïve fiancé", "Ünïçödé ACCENTS Straße",
    "你好世界 mixed 测试 text", "a  b\tc\n  d", "supercalifragilisticexpialidocious antidisestablishmentarianism",
    "email@example.com https://x.co/y?z=1 $5.00 <html> C++ #hashtag", "123 456.78 -90 1e10", "", "   ",
    "MiXeD CaSe WoRdS 42", "a\u0007b\u0000c", "a\u000bb\u000cc", "a\u007fb", "a​b﻿c", "a b c",
    "a�b", "\u0001\u0002\u0003", "  leading and trailing  ", "\t\n\r", "İstanbul", "STRASSE straße GROSS",
    "ﬁle ﬀ ﬄ", "ΟΔΟΣ Σίσυφος", "ＦＵＬＬＷＩＤＴＨ ａｂｃ", "é à ñ", "é à ñ ü ç", "Å Ω µ", "क्षत्रि",
    "Zoë Saldaña, born in Passaic (NJ), 1978.", "x̣́y ạ́b", "x́\u0001̣y",
    "q\U0001D16D\u0001\U0001D165z", "AbÀ\u0007C\td　E f", "ÉCOLE\nÜBER\r\nСЛОВО 東京Tokyo", "一鿿㐀䶿",
    "𠀀 𪛖 豈", "你好world世界", "，。、！？；：", "こんにちは カタカナ 안녕하세요", "a≤b x→y n≠m",
    "«guillemets» “smart” ‘quotes’", "em—dash en–dash …ellipsis", "e.g., i.e. U.S.A. 3.14 1,000",
    "!!!??? ((())) [a]{b}", "$100 €50 £20 ¥30 ₹40 ₿1", "hello 👋 world 🌍", "family 👨‍👩‍👧 ZWJ", "🇺🇸 🇯🇵 flags",
    "thumbs 👍🏽 skintone", "internationalization preprocessing tokenization playing", "ᚠᚢᚦ 𐐀𐐁 zzqxjk",
    "🎉party mixed🔥emoji", "a" * 100, "a" * 101, "字" * 120, "hello [MASK] world", "hello [mask] world",
    "[CLS] hi [SEP]", "[PAD][UNK][MASK]", "no special tokens here", "[MASK] [CLS] [SEP] [PAD] [UNK]",
    "foo[SEP]bar text[MASK]here", "[unk] lowercase specials", "It's 3:45 p.m. on 2026-10-05; the price is $1,299.99 (incl. 18% GST).",
    "Les élèves ont étudié l’histoire de la Révolution française.", "Größere Äpfel schmecken süßer als kleinere, sagt Jürgen.",
    "Москва — столица России, крупнейший город Европы.", "Η Αθήνα είναι η πρωτεύουσα της Ελλάδας.",
    "İstanbul’da çay içip simit yedik.", "Hà Nội là thủ đô của Việt Nam.", "مرحبا بالعالم، كيف حالك اليوم؟",
    "שלום עולם, מה שלומך?", "नमस्ते दुनिया, आज मौसम अच्छा है।", "कर्मण्येवाधिकारस्ते मा फलेषु कदाचन ।",
    "வணக்கம் உலகம், இன்று வானிலை நன்றாக உள்ளது.", "สวัสดีชาวโลก วันนี้อากาศดี", "你好，世界！今天天气很好。",
    "日本語の文章を正しく分割できますか？", "안녕하세요, 세계! 오늘 날씨가 좋네요.", "def f(x): return x**2  # squares\nprint(f(3))",
    "https://example.com/a/b?c=d&e=f#g user@example.org", "E = mc², ∑ᵢ xᵢ² ≤ ∞, ∀x∈ℝ ¯\\_(ツ)_/¯", " ", "\u0000\u0001\u001f\u007f",
    "tab\tsep\u000bvt\u000cff CRLF\r\nline\rcr", "  leading", "trailing  ", "a  b   c", " nbsp　ideographic thin",
    "​‌‍﻿bom", "<unk>", "<s>x</s>", "<pad></s>", "a<s>b <unk> c", "Hello World and hello world",
    "▁", "▁▁x", "\U0001F600 emoji 👩‍👩‍👧‍👦 👍🏽 🇮🇳", "ﬁ ﬂ Ⅻ ① ㎏ ㍿", "é é ñ ñ", "z̷̢̛a̴l̸g̵o̶",
    "ＦＵＬＬＷＩＤＴＨ ｶﾀｶﾅ", "𝔘𝔫𝔦𝔠𝔬𝔡𝔢 𝟙𝟚𝟛", "\U0010FFFF", "x" * 3000, "नम" * 2000, "[PAD]", "[UNK]x[UNK]",
    "à́̂b", "ﬁ́", "Ǻx", "각각 가", "👨‍👩‍👧‍👦👨🏻‍🦰",
    "क्‍ष", "क्ष्म", "\r\n\r\n", "ä̈b", "🇫🇷🇩🇪🇮🇹", "؀x", "xःy",
]

BLOCKS = [(0x20, 0x7e), (0xa0, 0xff), (0x300, 0x36f), (0x370, 0x3ff), (0x400, 0x4ff), (0x600, 0x6ff), (0x900, 0x97f),
          (0xb80, 0xbff), (0xe00, 0xe7f), (0x1100, 0x11ff), (0x2000, 0x206f), (0x3040, 0x30ff), (0x4e00, 0x4fff),
          (0xac00, 0xadff), (0xff00, 0xffef), (0x1f300, 0x1f6ff), (0x1f900, 0x1f9ff), (0x0, 0x1f), (0xfe00, 0xfe0f),
          (0x1f1e6, 0x1f1ff), (0x200b, 0x200d)]


def noise(n):
    rng = random.Random(20261106)
    out = []
    for _ in range(n):
        blocks = [rng.choice(BLOCKS) for _ in range(1 + rng.randrange(3))]
        s = []
        for _ in range(rng.randrange(60)):
            if rng.randrange(100) < 15:
                s.append(" ")
            else:
                lo, hi = rng.choice(blocks)
                c = rng.randint(lo, hi)
                if not 0xD800 <= c <= 0xDFFF:
                    s.append(chr(c))
        out.append("".join(s))
    return out


def main():
    tok = Tokenizer.from_file(sys.argv[1])
    tok.no_truncation()
    tok.no_padding()
    full = "--all" in sys.argv[3:]
    sets = [("edge", EDGE), ("noise", noise(3000 if full else 600))]
    for path in [a for a in sys.argv[3:] if a != "--all"]:
        name = path.rsplit("/", 1)[-1].split(".")[0]
        sets.append((name, [bytes.fromhex(l.strip()).decode("utf-8") for l in open(path) if l.strip()]))
    if full:
        sets.append(("codepoints", ["a" + chr(cp) + "b" for cp in range(0x110000) if not 0xD800 <= cp <= 0xDFFF]))
    with open(sys.argv[2], "w") as out:
        for name, texts in sets:
            for t, e in zip(texts, tok.encode_batch_fast(texts, add_special_tokens=False)):
                out.write(f"{name}\t{t.encode('utf-8').hex()}\t{','.join(map(str, e.ids))}\n")


main()
