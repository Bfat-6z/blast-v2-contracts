"""Whitespace-tolerant replacements for source-routing mutation checks."""

import re


def replace_code(source, old, new):
    tokens = re.findall(r"\w+|[^\w\s]", old)
    pattern = r"\s*".join(re.escape(token) for token in tokens)
    updated, count = re.subn(pattern, lambda _: new, source)
    assert count > 0, f"Missing mutation target: {old}"
    return updated
