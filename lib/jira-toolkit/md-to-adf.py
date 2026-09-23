#!/usr/bin/env python3
"""Convert a small markdown subset to Atlassian Document Format (ADF).

Supports: headings (#..######), bullet lists (-/*), ordered lists (N.),
bold (**text**), inline code (`text`), blank-line-separated paragraphs.
Reads markdown from stdin, writes an ADF doc (JSON) to stdout.

Wrapped continuation lines (a non-blank line that doesn't start a new
list item / heading / block) are folded into the same paragraph or list
item, joined by a space — plain text reflow, not a new block. A line
ending in a lone backslash forces an explicit line break at that point
(rendered as a hardBreak node — the Jira-UI shift+return equivalent)
instead of being space-joined with what follows.
"""
import json
import re
import sys

INLINE_RE = re.compile(r"(\*\*.+?\*\*|`.+?`|\*.+?\*)")
BULLET_RE = re.compile(r"^[-*]\s+(.*)$")
ORDERED_RE = re.compile(r"^\d+\.\s+(.*)$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")


def inline_nodes(text):
    nodes = []
    for token in INLINE_RE.split(text):
        if not token:
            continue
        if token.startswith("**") and token.endswith("**") and len(token) > 4:
            nodes.append({"type": "text", "text": token[2:-2], "marks": [{"type": "strong"}]})
        elif token.startswith("`") and token.endswith("`") and len(token) > 2:
            nodes.append({"type": "text", "text": token[1:-1], "marks": [{"type": "code"}]})
        elif token.startswith("*") and token.endswith("*") and len(token) > 2:
            nodes.append({"type": "text", "text": token[1:-1], "marks": [{"type": "em"}]})
        else:
            nodes.append({"type": "text", "text": token})
    return nodes or [{"type": "text", "text": text}]


def block_content(lines):
    """Fold a block's wrapped lines into one paragraph's content nodes.

    Lines are space-joined (reflow) except where a line ends with a lone
    trailing backslash, which forces a hardBreak instead.
    """
    segments = []
    current = []
    for line in lines:
        if line.endswith("\\"):
            current.append(line[:-1].rstrip())
            segments.append(" ".join(current))
            current = []
        else:
            current.append(line)
    if current:
        segments.append(" ".join(current))

    nodes = []
    for idx, seg in enumerate(segments):
        if idx > 0:
            nodes.append({"type": "hardBreak"})
        nodes.extend(inline_nodes(seg))
    return nodes


def is_block_start(stripped):
    """True if this line starts a NEW block (list item, heading) rather
    than continuing the current one."""
    if not stripped:
        return True
    return bool(BULLET_RE.match(stripped) or ORDERED_RE.match(stripped) or HEADING_RE.match(stripped))


def consume_continuations(lines, i, n, first_text):
    """Collect first_text plus any wrapped continuation lines following it."""
    block_lines = [first_text]
    while i < n:
        nxt = lines[i].strip()
        if is_block_start(nxt):
            break
        block_lines.append(nxt)
        i += 1
    return block_lines, i


def list_item(lines):
    return {"type": "listItem", "content": [{"type": "paragraph", "content": block_content(lines)}]}


def consume_list(lines, i, n, marker_re):
    """Consume consecutive items of one list (same marker style). A blank
    line between items keeps the list going (a "loose" list) as long as
    the next non-blank line is another item of the same marker; anything
    else ends the list."""
    items = []
    while True:
        j = i
        while j < n and not lines[j].strip():
            j += 1
        if j >= n:
            i = j
            break
        m = marker_re.match(lines[j].strip())
        if not m:
            break
        i = j + 1
        block_lines, i = consume_continuations(lines, i, n, m.group(1))
        items.append(list_item(block_lines))
    return items, i


def parse(md):
    lines = md.split("\n")
    content = []
    i = 0
    n = len(lines)
    while i < n:
        stripped = lines[i].strip()

        if not stripped:
            i += 1
            continue

        heading = HEADING_RE.match(stripped)
        if heading:
            level = len(heading.group(1))
            content.append({"type": "heading", "attrs": {"level": level}, "content": inline_nodes(heading.group(2))})
            i += 1
            continue

        bullet = BULLET_RE.match(stripped)
        if bullet:
            items, i = consume_list(lines, i, n, BULLET_RE)
            content.append({"type": "bulletList", "content": items})
            continue

        ordered = ORDERED_RE.match(stripped)
        if ordered:
            items, i = consume_list(lines, i, n, ORDERED_RE)
            content.append({"type": "orderedList", "content": items})
            continue

        i += 1
        block_lines, i = consume_continuations(lines, i, n, stripped)
        content.append({"type": "paragraph", "content": block_content(block_lines)})

    if not content:
        content = [{"type": "paragraph", "content": [{"type": "text", "text": md}]}]

    return {"type": "doc", "version": 1, "content": content}


def main():
    md = sys.stdin.read()
    print(json.dumps(parse(md)))


if __name__ == "__main__":
    main()
