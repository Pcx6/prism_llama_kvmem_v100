#!/usr/bin/env python3
"""Small correctness gate: greedy consistency, needle retrieval, long reasoning."""
import argparse, json, sys, time, urllib.request

def chat(base, key, messages, max_tokens=128, temperature=0.0):
    body = json.dumps({
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "cache_prompt": False,
    }).encode()
    req = urllib.request.Request(
        base.rstrip("/") + "/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=1800) as r:
        d = json.load(r)
    m = d["choices"][0]["message"]
    txt = (m.get("content") or "") + (m.get("reasoning_content") or "")
    return txt, d.get("timings", {}), time.time() - t0

def build_needle(tokens=32000):
    target = tokens * 5
    codes = [("START-GATE-11", 1000), ("MIDDLE-GATE-22", target // 2), ("END-GATE-33", target - 2000)]
    seen = {c: False for c, _ in codes}
    parts, size, n = [], 0, 0
    while size < target:
        n += 1
        line = "Line %d: " % n + ("The quick brown fox jumps over the lazy dog while KV pages move. " * 3) + "\n"
        for c, pos in codes:
            if not seen[c] and size >= pos:
                line = "IMPORTANT CODE: %s\n" % c + line
                seen[c] = True
        parts.append(line)
        size += len(line)
    parts.append("\nList all hyphenated code names above.\n")
    return "".join(parts), [c for c, _ in codes]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:14802")
    ap.add_argument("--key", required=True)
    ap.add_argument("--skip-needle", action="store_true")
    args = ap.parse_args()
    results = []

    a, _, _ = chat(args.base, args.key, [{"role": "user", "content": "Write exactly: hello world"}], 32)
    b, _, _ = chat(args.base, args.key, [{"role": "user", "content": "Write exactly: hello world"}], 32)
    results.append(("greedy_repeat", a == b, (a[:80], b[:80])))

    txt, _, _ = chat(args.base, args.key, [{"role": "user", "content": "A box has 17 red balls and 9 blue balls. How many red balls? Reply with the number only."}], 64)
    results.append(("arithmetic", "17" in txt, txt[:80]))

    if not args.skip_needle:
        corpus, codes = build_needle()
        txt, tim, wall = chat(args.base, args.key, [{"role": "user", "content": corpus}], 256)
        found = [c for c in codes if c in txt]
        results.append(("needle", len(found) == len(codes), "%d/%d found: %s (prompt=%s, %0.1fs)" % (
            len(found), len(codes), ",".join(found), tim.get("prompt_n"), wall)))

    ok = True
    for name, passed, detail in results:
        print("%-14s %s %s" % (name, "PASS" if passed else "FAIL", detail))
        ok = ok and passed
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
