"""Render bounded trusted CLI detail text; never execute or interpret its markup."""
import os
import re
import sys

raw = open(sys.argv[1], encoding="utf-8").read(100000)
lines = [line.replace("`", "'")[:200] for line in raw.splitlines()[:400]]
url = os.environ.get("EVIDENCE_URL", "")
if not re.fullmatch(r"https://[A-Za-z0-9.-]+(?::[0-9]+)?/#history/ci/act_[A-Za-z0-9_-]{1,80}", url):
    url = ""
groups = []
for line in lines:
    if re.fullmatch(r"  [A-Za-z0-9][A-Za-z0-9._/-]{0,119}", line):
        groups.append((line.strip(), []))
    elif groups:
        groups[-1][1].append(line)
if not groups or not any("    What happened:" in block for _, block in groups):
    # Older CLI receipts remain literal and do not gain invented explanations.
    print("**What your agent did**\n\n```text\n" + "\n".join(lines) + "\n```")
else:
    print("**What your agent did**")
    omitted = len(groups) > 12 or "DETAILS_TRUNCATED" in lines or len(raw.splitlines()) > 400
    for key, block in groups[:12]:
        required = ("    What happened:", "    Why it's unsafe:", "    How to fix it:")
        if any(label not in block for label in required) or "DETAILS_TRUNCATED" in block:
            omitted = True
            continue
        print("\n#### Finding: `" + key + "`")
        sections = []
        for line in block:
            if line in ("    What happened:", "    Why it's unsafe:", "    How to fix it:"):
                sections.append((line.strip()[:-1], []))
            elif sections:
                sections[-1][1].append(line.strip())
        for title, text in sections:
            content = "\n".join(text)
            if len(content) > 1200:
                content = content[:1200] + "\n[Additional details in the full run.]"
                omitted = True
            print("\n**" + title + "**\n\n```text\n" + content + "\n```")
        print("\nPush a fix to rerun the normal task and attack tests. Retests of this PR are included.")
        if url:
            print("\n[View evidence for this finding](" + url + ") — find `" + key + "` in this run. Sign-in required.")
        else:
            print("\nEvidence link unavailable; inspect the recorded run before treating this finding as verified.")

    if omitted:
        print("\n**Some findings or details are omitted from this bounded comment. Inspect the full run before merging.**")
        if url:
            print("\n[View all findings and evidence](" + url + ")")
