#!/usr/bin/env python3
"""Embed runner/runner.zsh into a Swift constant so the app can (re)install it."""
import hashlib
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    content = f.read().rstrip("\n")
digest = hashlib.sha256(content.encode()).hexdigest()[:12]
with open(dst, "w") as f:
    f.write("// Generated from runner/runner.zsh - do not edit. Run `make gen`.\n")
    f.write("enum RunnerScript {\n")
    f.write(f'    static let version = "{digest}"\n')
    f.write('    static let contents = #"""\n')
    f.write(content + "\n")
    f.write('"""#\n')
    f.write("}\n")
print(f"generated {dst} ({digest})")
