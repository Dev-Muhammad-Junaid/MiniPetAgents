#!/usr/bin/env python3
"""Register a Swift file with the Xcode project.

The project lists every source file explicitly (objectVersion 56, no
file-system-synchronized groups), so a new .swift file is invisible to the
build until it has a PBXFileReference, a PBXBuildFile, a slot in the group's
children and a slot in the Sources build phase. Doing that by hand is fiddly
and easy to half-do; this does all four.

    ./scripts/add-swift-file.py NotchWindow.swift
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBX = ROOT / "app/MiniPetAgents.xcodeproj/project.pbxproj"
BUILD_PREFIX = "A100000100000000000000"
REF_PREFIX = "A100000200000000000000"


def next_suffix(text):
    used = {int(m, 16) for m in re.findall(rf"{REF_PREFIX}([0-9A-F]{{2}})", text)}
    used |= {int(m, 16) for m in re.findall(rf"{BUILD_PREFIX}([0-9A-F]{{2}})", text)}
    n = max(used) + 1
    if n > 0xFF:
        sys.exit("ran out of ids in this prefix — widen the scheme")
    return f"{n:02X}"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    name = sys.argv[1]
    if not name.endswith(".swift"):
        sys.exit("expected a .swift file name")
    if not (ROOT / "app/MiniPetAgents" / name).exists():
        sys.exit(f"app/MiniPetAgents/{name} does not exist — write it first")

    text = PBX.read_text()
    if f"/* {name} */" in text:
        print(f"{name} is already registered")
        return

    sfx = next_suffix(text)
    build_id, ref_id = BUILD_PREFIX + sfx, REF_PREFIX + sfx

    # 1. PBXBuildFile, beside an existing one
    anchor = re.search(r"(\t\t[0-9A-F]{24} /\* \S+\.swift in Sources \*/ = \{isa = PBXBuildFile.*?\};\n)", text)
    text = text[:anchor.end()] + (
        f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {ref_id} /* {name} */; }};\n") + text[anchor.end():]

    # 2. PBXFileReference
    anchor = re.search(r"(\t\t[0-9A-F]{24} /\* \S+\.swift \*/ = \{isa = PBXFileReference.*?\};\n)", text)
    text = text[:anchor.end()] + (
        f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n"
    ) + text[anchor.end():]

    # 3. group children
    anchor = re.search(r"(\t{4}[0-9A-F]{24} /\* \S+\.swift \*/,\n)", text)
    text = text[:anchor.end()] + f"\t\t\t\t{ref_id} /* {name} */,\n" + text[anchor.end():]

    # 4. Sources build phase
    anchor = re.search(r"(\t{4}[0-9A-F]{24} /\* \S+\.swift in Sources \*/,\n)", text)
    text = text[:anchor.end()] + f"\t\t\t\t{build_id} /* {name} in Sources */,\n" + text[anchor.end():]

    PBX.write_text(text)
    print(f"registered {name} (ref {ref_id}, build {build_id})")


if __name__ == "__main__":
    main()
