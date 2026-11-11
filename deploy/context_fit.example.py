"""How much does matching context lift engagement, per format?

  python3 -I deploy/context_fit.example.py engagement.tsv sites.tsv [categories.tsv]

engagement.tsv, under a header line: domain, format, advertiser category,
impressions, engagements (e.g. 30 days of your ad server's reporting).
sites.tsv: a site's profile as the lab keeps it, its ctx:section:<site> hash
(src/serve/lab.ml) on one line, "site<TAB>#pages<TAB>n<TAB>id<TAB>sum<TAB>...":
  { printf 'example.com\t'; valkey-cli --raw HGETALL ctx:section:example.com | paste -sd '\t' -; }
A site's score for a category is the mean of its pages' scores (sum / pages).
categories.tsv maps your advertiser categories onto IAB Content Taxonomy 3.1
ids, "category<TAB>id[,id...]" per line; without it, the illustrative
CATEGORIES below. The match is the best of a category's ids.

Per format, a binomial GLM, logit(engagement rate) = alpha[category] +
beta * match, fitted by IRLS; category fixed effects absorb how engaging each
vertical's creatives are. beta's interval comes from resampling sites.
With delivery reported per site, not per page or slot, this is the page-level
feature at site grain. The local feature (blocks around the slot) needs the
slot geometry the Prebid module logs (sdks/prebid).
"""

import math
import random
import sys
from collections import defaultdict

# Illustrative: advertiser categories named after IAB tier-1 categories.
CATEGORIES = {
    "Automotive": ["1"],
    "Business and Finance": ["52", "391"],
    "Food & Drink": ["210"],
    "Health": ["223", "286"],
    "Style & Fashion": ["552"],
    "Travel": ["653"],
}
MIN_PAGES = 5  # sites with fewer crawled pages are left out


def host(d):
    d = d.lower().strip()
    return d[4:] if d.startswith("www.") else d


def load_sites(path):
    sites = {}
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if len(f) < 3:
            continue
        kv = dict(zip(f[1::2], f[2::2]))
        pages = int(float(kv.pop("#pages", "0")))
        if pages >= MIN_PAGES:
            sites[f[0]] = {k: float(v) / pages for k, v in kv.items()}
    return sites


def solve(a, b):
    """Gaussian elimination with partial pivoting: a x = b."""
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        if abs(m[p][c]) < 1e-12:
            m[p][c] = 1e-12
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                f = m[r][c] / m[c][c]
                for k in range(c, n + 1):
                    m[r][k] -= f * m[c][k]
    return [m[i][n] / m[i][i] for i in range(n)]


def glm(rows, cats):
    """IRLS for logit(p) = alpha[cat] + beta * x on aggregated binomial rows
    (cat, x, n, k). Returns (alpha by category, beta)."""
    idx = {c: i for i, c in enumerate(cats)}
    dim = len(cats) + 1
    theta = [0.0] * dim
    for c in cats:
        n = sum(r[2] for r in rows if r[0] == c)
        k = sum(r[3] for r in rows if r[0] == c)
        p = min(max(k / n if n else 0.01, 1e-6), 1 - 1e-6)
        theta[idx[c]] = math.log(p / (1 - p))
    for _ in range(50):
        h = [[0.0] * dim for _ in range(dim)]
        g = [0.0] * dim
        for c, x, n, k in rows:
            z = [0.0] * dim
            z[idx[c]] = 1.0
            z[-1] = x
            eta = sum(a * b for a, b in zip(theta, z))
            p = 1 / (1 + math.exp(-eta))
            w = n * p * (1 - p)
            for i in range(dim):
                if z[i]:
                    g[i] += (k - n * p) * z[i]
                    for j in range(dim):
                        if z[j]:
                            h[i][j] += w * z[i] * z[j]
        step = solve(h, g)
        theta = [t + s for t, s in zip(theta, step)]
        if max(abs(s) for s in step) < 1e-9:
            break
    return {c: theta[idx[c]] for c in cats}, theta[-1]


def load_categories(path):
    cats = {}
    for line in open(path):
        f = line.rstrip("\n").split("\t")
        if len(f) == 2 and f[1]:
            cats[f[0]] = [i.strip() for i in f[1].split(",")]
    return cats


def main():
    sites = load_sites(sys.argv[2])
    categories = load_categories(sys.argv[3]) if len(sys.argv) > 3 else CATEGORIES
    by_format = defaultdict(list)
    for line in list(open(sys.argv[1]))[1:]:
        d, fmt, cat, n, k = line.rstrip("\n").split("\t")
        s = sites.get(host(d))
        if s is None or cat not in categories or int(n) == 0:
            continue
        x = max(s.get(i, 0.0) for i in categories[cat])
        by_format[fmt].append((cat, x, int(n), int(k), host(d)))
    random.seed(0)
    print("| format | sites | rows | impressions | engagement rate | beta (match 0 to 1) | 90% interval | ER at match 0 / 0.5 |")
    print("|---|---|---|---|---|---|---|---|")
    for fmt in sorted(by_format, key=lambda f: -sum(r[2] for r in by_format[f])):
        rows = by_format[fmt]
        sites_f = sorted({r[4] for r in rows})
        if len(sites_f) < 8:
            continue
        cats = sorted({r[0] for r in rows})
        alpha, beta = glm([r[:4] for r in rows], cats)
        boot = []
        for _ in range(200):
            pick = [random.choice(sites_f) for _ in sites_f]
            sample = [r[:4] for s in pick for r in rows if r[4] == s]
            cs = sorted({r[0] for r in sample})
            boot.append(glm(sample, cs)[1])
        boot.sort()
        n = sum(r[2] for r in rows)
        k = sum(r[3] for r in rows)
        a = sum(alpha[r[0]] * r[2] for r in rows) / n
        er = lambda m: 1 / (1 + math.exp(-(a + beta * m)))
        # 90% interval: the 5th and 95th percentiles of the 200 resampled betas.
        print(
            f"| {fmt} | {len(sites_f)} | {len(rows)} | {n:,} | {k / n:.3%} | {beta:+.2f} | "
            f"{boot[10]:+.2f} to {boot[189]:+.2f} | {er(0):.3%} / {er(0.5):.3%} |"
        )


if __name__ == "__main__":
    main()
