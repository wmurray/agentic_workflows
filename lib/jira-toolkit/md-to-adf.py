#!/usr/bin/env python3
"""Convert a small markdown subset to Atlassian Document Format (ADF).

Supports: headings (#..######), bullet lists (-/*), ordered lists (N.),
blockquotes (> lines), fenced code blocks (``` with an optional language),
bold (**text**), inline code (`text`), blank-line-separated paragraphs.
Reads markdown from stdin, writes an ADF doc (JSON) to stdout.

Consecutive > lines form one blockquote; a bare > line splits it into
paragraphs. Fenced code is kept verbatim (no inline marks, newlines kept),
and an unclosed fence runs to the end of the input. An ordered list that
resumes after a code block or blockquote continues the earlier list's
numbering (attrs.order), unless its first marker is an explicit "1.".

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
QUOTE_RE = re.compile(r"^>\s?(.*)$")
FENCE_RE = re.compile(r"^(`{3,})\s*([^`\s]*)[^`]*$")
ORDERED_NUM_RE = re.compile(r"^(\d+)\.\s")


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
    """True if this line starts a NEW block (list item, heading, quote,
    fence) rather than continuing the current one."""
    if not stripped:
        return True
    return bool(
        BULLET_RE.match(stripped)
        or ORDERED_RE.match(stripped)
        or HEADING_RE.match(stripped)
        or QUOTE_RE.match(stripped)
        or FENCE_RE.match(stripped)
    )


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


def consume_fence(lines, i, n, fence):
    """Collect the raw lines after an opening fence up to the closing fence
    (a backtick run at least as long, with nothing else on the line)."""
    body = []
    while i < n:
        closing = lines[i].strip()
        if closing.startswith(fence) and not closing.strip("`"):
            return body, i + 1
        body.append(lines[i])
        i += 1
    return body, i


def code_block(body, language):
    node = {"type": "codeBlock"}
    if language:
        node["attrs"] = {"language": language}
    text = "\n".join(body)
    node["content"] = [{"type": "text", "text": text}] if text else []
    return node


def consume_quote(lines, i, n):
    """Consume consecutive > lines into one blockquote. A bare > line
    separates paragraphs inside it."""
    paragraphs = [[]]
    while i < n:
        m = QUOTE_RE.match(lines[i].strip())
        if not m:
            break
        inner = m.group(1).strip()
        if inner:
            paragraphs[-1].append(inner)
        elif paragraphs[-1]:
            paragraphs.append([])
        i += 1
    content = [{"type": "paragraph", "content": block_content(p)} for p in paragraphs if p]
    return {"type": "blockquote", "content": content or [{"type": "paragraph", "content": []}]}, i


def resumed_order(content, first_marker):
    """Start number for an ordered list that resumes one interrupted by
    code blocks or blockquotes; None for a fresh list."""
    if first_marker == 1:
        return None
    j = len(content) - 1
    while j >= 0 and content[j]["type"] in ("codeBlock", "blockquote"):
        j -= 1
    if j == len(content) - 1 or j < 0 or content[j]["type"] != "orderedList":
        return None
    prev = content[j]
    return prev.get("attrs", {}).get("order", 1) + len(prev["content"])


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
            order = resumed_order(content, int(ORDERED_NUM_RE.match(stripped).group(1)))
            items, i = consume_list(lines, i, n, ORDERED_RE)
            node = {"type": "orderedList", "content": items}
            if order is not None:
                node["attrs"] = {"order": order}
            content.append(node)
            continue

        fence = FENCE_RE.match(stripped)
        if fence:
            body, i = consume_fence(lines, i + 1, n, fence.group(1))
            content.append(code_block(body, fence.group(2)))
            continue

        if QUOTE_RE.match(stripped):
            node, i = consume_quote(lines, i, n)
            content.append(node)
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
