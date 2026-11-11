"""LLM pre-adjudication for the golden set.

  python3 -I deploy/adjudicate.py --limit 10            # pilot
  python3 -I deploy/adjudicate.py --cap 2.00            # all pages
  python3 -I deploy/adjudicate.py --lang it,fr --text 4000 --compare \
      --out src/store/adjudication_llm_text             # second, in-language pass

Reads the candidates the Placement Lab shows a human (GET /api/adjudication),
asks an OpenRouter model to keep/drop/add IAB Content Taxonomy 3.1 categories,
and writes the judgement back (POST /api/adjudication). It therefore fills the
same store the lab exports at /api/adjudication.tsv, so a human can still
review and correct any page before the report runs.

The prompt starts from the lab's default ticks (deep >= 0.5) and gives every
candidate's tier scores and evidence quotes rather than the raw page. All IDs
are checked against the taxonomy; a label the model invents is dropped.

--lang keeps pages whose declared language (<html lang>, else og:locale, from
the golden report's cache) is listed; --text adds the page's main text as the
crawler extracted it, so the judge reads the page in its own language;
--compare writes the judgements to --out only, and prints the hierarchical
agreement with the saved ones instead of replacing them.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://openrouter.ai/api/v1/chat/completions"


def key(env_file):
    if os.environ.get("OPENROUTER_API_KEY"):
        return os.environ["OPENROUTER_API_KEY"]
    for line in open(env_file):
        if line.startswith("OPENROUTER_API_KEY="):
            return line.split("=", 1)[1].strip().strip("\"'")
    sys.exit("OPENROUTER_API_KEY not in the environment nor in " + env_file)


def post(url, body, headers):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)


def get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def taxonomy(path, parent=None):
    parent, name = {} if parent is None else parent, {}
    lines = open(path).read().splitlines()[2:]
    for line in lines:
        cols = line.split("\t")
        if len(cols) > 2 and cols[0]:
            parent[cols[0]] = cols[1] or None
            name[cols[0]] = cols[2]

    def chain(i):
        out = []
        while i:
            out.append(name.get(i, i))
            i = parent.get(i)
        return list(reversed(out))

    return {i: " > ".join(chain(i)) for i in name}


def closure(ids, parent):
    out = set()
    for i in ids:
        while i and i not in out:
            out.add(i)
            i = parent.get(i)
    return out


def declared_lang(cache, url):
    try:
        html = open(os.path.join(cache, hashlib.sha256(url.encode()).hexdigest()), errors="replace").read(200_000)
    except OSError:
        return ""
    m = re.search(r"<html\b[^>]*?\blang\s*=\s*[\"']?([A-Za-z]{2})(?:[-_][A-Za-z]+)?\b", html, re.I) or re.search(
        r"<meta\b[^>]*?property\s*=\s*[\"']og:locale[\"'][^>]*?content\s*=\s*[\"']([A-Za-z]{2})", html, re.I
    )
    return m.group(1).lower() if m else ""


def page_text(lab, url, limit):
    page = get(f"{lab}/api/page?" + urllib.parse.urlencode({"url": url, "level": "deep"}))
    text = "\n".join(s["text"] for s in page.get("segments") or [] if s.get("main") and s.get("text"))
    return (page.get("title") or "") + "\n" + text[:limit]


def prompt(url, candidates, cats, text=""):
    defaults = [c["id"] for c in candidates if (c.get("scores") or {}).get("deep", 0) >= 0.5]
    rows = []
    for c in candidates:
        scores = " ".join(f"{k}={v:.2f}" for k, v in sorted((c.get("scores") or {}).items()))
        evidence = "; ".join(
            f'[{e["tier"]}] {e["quote"][:200]}' for e in (c.get("evidence") or [])[:3]
        )
        rows.append(
            f'{c["id"]}\t{c["path"]}\tsensitive={"yes" if c.get("sensitive") else "no"}\t'
            f"scores {scores}\tevidence: {evidence}"
        )
    tax = "\n".join(f"{i}\t{p}" for i, p in sorted(cats.items(), key=lambda x: x[1]))
    return f"""You are adjudicating a golden set for contextual advertising with the IAB Content Taxonomy 3.1.
Tag every category the page is about. Judge from the URL, the candidates and their evidence:
a tier's score alone is not evidence, and a quote must show the page is actually about the category.
The deep level's ticks are a starting point, not truth: drop the wrong ones and add what every level missed.
Prefer the most specific correct node; the hierarchy adds its parents automatically.
A page can have several categories. Sensitive Topics count when the page is about them.

URL: {url}
{"" if not text else chr(10) + "PAGE TEXT (title, then the main content as extracted; read it in its own language):" + chr(10) + text + chr(10)}
DEFAULT TICKS (deep >= 0.5): {", ".join(defaults) if defaults else "none"}

CANDIDATES (id, path, sensitive, tier scores, evidence quotes):
{chr(10).join(rows)}

TAXONOMY (id, path):
{tax}

Return only JSON with two arrays of taxonomy ids:
{{"gold": ["id", ...], "rejected": ["id", ...]}}
gold = every category the page is about; rejected = candidate ids that are wrong or too broad.
Do not repeat a gold id in rejected. Do not invent ids."""


def parse(content):
    content = content.strip()
    if content.startswith("```"):
        content = re.sub(r"^```[a-zA-Z]*\n?", "", content)
        content = re.sub(r"\n?```$", "", content)
    j = json.loads(content)
    return j.get("gold") or [], j.get("rejected") or []


def one(args, cats, page, cost_lock):
    url = page["url"]
    if page.get("adjudicated") and not (args.force or args.compare):
        return ("skip", url, 0.0, 0, 0)
    with cost_lock:
        if args.spent >= args.cap:
            return ("cap", url, 0.0, 0, 0)
    adj = get(f"{args.lab}/api/adjudication?" + urllib.parse.urlencode({"url": url}))
    candidates = adj["candidates"]
    text = page_text(args.lab, url, args.text) if args.text else ""
    body = {
        "model": args.model,
        "messages": [{"role": "user", "content": prompt(url, candidates, cats, text)}],
        "temperature": 0,
        "max_tokens": 1500,
        "response_format": {"type": "json_object"},
        "provider": {"data_collection": "deny"},
        "usage": {"include": True},
        "reasoning": {"enabled": False},
    }
    headers = {
        "Authorization": "Bearer " + args.key,
        "Content-Type": "application/json",
        "X-Title": "contextual-golden-adjudication",
    }
    # A model without JSON mode refuses response_format with 400 or 404: retry
    # without it. Back off on timeouts, rate limits and server errors.
    for attempt in range(4):
        try:
            rep = post(API, body, headers)
            break
        except urllib.error.HTTPError as e:
            if e.code in (400, 404) and "response_format" in body:
                body.pop("response_format")
                continue
            if e.code not in (408, 429, 500, 502, 503, 504) or attempt == 3:
                raise
            time.sleep(2 ** attempt)
    content = rep["choices"][0]["message"].get("content") or ""
    gold, _ = parse(content)
    # The model's own "rejected" is not used: every candidate it did not keep is rejected.
    gold = list(dict.fromkeys(str(g) for g in gold if str(g) in cats))
    rejected = [c["id"] for c in candidates if c["id"] not in gold]
    cost = float((rep.get("usage") or {}).get("cost") or 0)
    usage = rep.get("usage") or {}
    with cost_lock:
        args.spent += cost
        if args.compare:
            before = closure((adj.get("saved") or {}).get("gold") or [], args.parent)
            after = closure(gold, args.parent)
            args.agree.append((len(before & after), len(before), len(after)))
    if not args.compare:
        post(
            f"{args.lab}/api/adjudication",
            {"url": url, "gold": gold, "rejected": rejected},
            {"Content-Type": "application/json"},
        )
    with open(os.path.join(args.out, hashlib.sha256(url.encode()).hexdigest() + ".json"), "w") as f:
        json.dump({"url": url, "gold": gold, "rejected": rejected, "raw": content, "usage": usage}, f, indent=1)
    return ("ok", url, cost, usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lab", default="http://localhost:8092")
    ap.add_argument("--taxonomy", default="src/data/content_taxonomy_3.1.tsv")
    ap.add_argument("--model", default="deepseek/deepseek-v4.1-flash-1017")
    ap.add_argument("--env", default="src/.env")
    ap.add_argument("--out", default="src/store/adjudication_llm")
    ap.add_argument("--limit", type=int, default=0, help="0 = all unjudged pages")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--cap", type=float, default=2.0, help="stop when billed USD reaches this")
    ap.add_argument("--force", action="store_true", help="redo pages already judged")
    ap.add_argument("--lang", default="", help="comma-separated declared languages to keep, e.g. it,fr")
    ap.add_argument("--cache", default="src/store/golden", help="the golden report's page cache")
    ap.add_argument("--text", type=int, default=0, help="chars of main page text in the prompt (0 = none)")
    ap.add_argument("--compare", action="store_true", help="do not save; print agreement with the saved gold")
    args = ap.parse_args()
    args.key = key(args.env)
    args.spent = 0.0
    os.makedirs(args.out, exist_ok=True)
    args.parent, args.agree = {}, []
    cats = taxonomy(args.taxonomy, args.parent)
    pages = get(args.lab + "/api/pages")
    todo = [p for p in pages if args.force or args.compare or not p.get("adjudicated")]
    if args.lang:
        langs = set(args.lang.split(","))
        todo = [p for p in todo if declared_lang(args.cache, p["url"]) in langs]
    if args.limit:
        todo = todo[: args.limit]
    print(f"{len(pages)} pages, {len(todo)} to judge with {args.model}", flush=True)
    cost_lock = threading.Lock()
    started = time.time()
    counts = {"ok": 0, "skip": 0, "cap": 0}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(one, args, cats, p, cost_lock) for p in todo]
        for fut in concurrent.futures.as_completed(futures):
            try:
                status, url, cost, ptok, ctok = fut.result()
            except Exception as e:
                print(f"FAIL {e}", flush=True)
                continue
            counts[status] = counts.get(status, 0) + 1
            if status == "ok":
                print(
                    f"{counts['ok']:4d}/{len(todo)} ${args.spent:.4f} "
                    f"{ptok}+{ctok} tok  {url[:100]}",
                    flush=True,
                )
    print(
        f"done: {counts.get('ok',0)} judged, {counts.get('skip',0)} skipped, "
        f"${args.spent:.4f}, {time.time() - started:.0f}s",
        flush=True,
    )
    if args.agree:
        hit, before, after = (sum(x[i] for x in args.agree) for i in range(3))
        p, r = hit / max(after, 1), hit / max(before, 1)
        print(f"agreement with the saved gold (closed under ancestors): hP {p:.3f} hR {r:.3f} hF1 {2*p*r/max(p+r,1e-9):.3f}")


if __name__ == "__main__":
    main()
