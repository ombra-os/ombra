#!/usr/bin/env python3
"""Parser-state walker for d-i late-command scripts: catches
parse-balanced-but-fatal corruption bash -n cannot (unterminated
heredocs, multi-line quoted regions, quoted regions swallowing
comment lines).
"""
import sys

def scan(path):
    lines = open(path).readlines()
    problems = []
    state = 'code'; opener = 0; content = []
    pending = []  # heredoc delimiters
    n = 0
    while n < len(lines):
        n += 1
        raw = lines[n-1].rstrip('\n')
        if state == 'heredoc':
            for h in list(pending):
                if raw.strip() == h[0]:
                    pending.remove(h)
            if not pending:
                state = 'code'
            continue
        i = 0
        while i < len(raw):
            c = raw[i]
            if state == 'single':
                if c == "'":
                    span = n - opener
                    if span > 3:
                        problems.append(f"line {opener}: quoted region spans {span} lines (soft-sh-c/seeasaw class)")
                    for cl in content:
                        if cl.lstrip().startswith('#'):
                            problems.append(f"line {opener}: quoted region swallows comment lines (line {n - len(content) + content.index(cl) + 1}: {cl.strip()[:50]})")
                            break
                    content = []; state = 'code'
                else:
                    if i == 0: content.append(raw)
            elif state == 'double':
                if c == '\\': i += 1
                elif c == '"':
                    span = n - opener
                    if span > 3:
                        problems.append(f"line {opener}: double-quoted region spans {span} lines")
                    content = []; state = 'code'
                else:
                    if i == 0: content.append(raw)
            else:
                if c == '#': break
                if c == "'": state = 'single'; opener = n; content = [raw]
                elif c == '"': state = 'double'; opener = n; content = [raw]
                elif c == '\\': i += 1
                elif raw.startswith('<<', i):
                    rest = raw[i+2:].strip().rstrip(';').strip()
                    if rest[:1] in ("'", '"'):
                        rest = rest.strip("'\"").split()[0] if rest.strip("'\"") else ''
                    else:
                        rest = rest.split()[0] if rest.split() else ''
                    if rest:
                        pending.append((rest, n)); state = 'heredoc'; break
            i += 1
    for h in pending:
        problems.append(f"line {h[1]}: heredoc <<{h[0]} never closed (swallows script tail)")
    if state in ('single', 'double'):
        problems.append(f"line {opener}: {state}-quoted region still open at EOF")
    return problems

bad = 0
for p in sys.argv[1:]:
    for pr in scan(p):
        print(f"FAIL {p}: {pr}"); bad = 1
sys.exit(bad)
