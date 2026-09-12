#!/usr/bin/env python3
"""Fails if tvOS gains a control that would draw its own focus plate.

tvOS marks whatever has focus by painting a plate behind it, sized to the
whole control. Every focusable surface in this app draws its own focus
instead -- a fill, a lift, a border -- so that plate lands on top as a second,
much larger highlight. That is the "bulky frame" this app spent a long time
getting rid of, and it comes back the moment someone adds a plain Button.

A control is safe when a button style is set on it or on anything it sits
inside, or when it sits inside a container tvOS draws entirely itself -- an
alert, a context menu, a confirmation dialog, a toolbar. Those are system
chrome, not app layout.

`Menu` is never safe. It renders through tvOS's own chrome whatever button
style it is given, which is why the ones this app used became TVSelectable
with a confirmationDialog instead.

Run from the repository root:

    python3 Tools/check-tv-focus.py
"""

import re
import sys

# What the tvOS target compiles. The iPhone tree is not its problem.
TARGET_FILES = [
    "Lineup/Views/ChannelViews.swift",
    "Lineup/Views/MediaViews.swift",
    "Lineup/Views/RootView.swift",
    "Lineup/Design/LineupStyle.swift",
    "Lineup/Design/TeamBadge.swift",
    "Lineup/LineupApp.swift",
]

# Modifiers that replace tvOS's default button style.
#
# focusEffectDisabled() is deliberately not among them. It suppresses the
# focus *effect*, but tvOS's default button style is a card -- a large rounded
# background that is part of the style itself, not the effect -- and that card
# is the bulky frame. Only giving the button a different style removes it.
#
# A style set on a container counts: SwiftUI passes button styles down through
# the environment, so `HStack { Button; Button }.lineupButtonStyle()` dresses
# both, and much of this app is written that way.
SAFE = ("lineupFlatButton", "lineupButtonStyle", "buttonStyle")

# Containers tvOS draws itself, where a plain Button is the correct thing.
SYSTEM_CONTAINERS = (".alert(", ".contextMenu", ".confirmationDialog(", ".toolbar")


def tvos_lines(source):
    """The lines the tvOS compiler sees, keeping original line numbers."""
    kept, stack = [], []
    for number, line in enumerate(source.split("\n"), 1):
        text = line.strip()
        opened = re.match(r"^#if\s+(.*)$", text)
        if opened:
            condition = opened.group(1)
            live = ("!" not in condition) if "os(tvOS)" in condition else True
            stack.append([live, live])
            continue
        if re.match(r"^#elseif\b", text):
            frame = stack[-1]
            frame[0] = not frame[1]
            frame[1] = frame[1] or frame[0]
            continue
        if text == "#else":
            frame = stack[-1]
            frame[0] = not frame[1]
            frame[1] = True
            continue
        if text == "#endif":
            stack.pop()
            continue
        if all(frame[0] for frame in stack):
            kept.append((number, line))
    return kept


def delta(line):
    return line.count("{") - line.count("}")


def depths(lines):
    """Brace depth at the start of each line, by position in `lines`."""
    result, depth = [], 0
    for _, line in lines:
        result.append(depth)
        depth += delta(line)
    return result


def statement_end(lines, line_depths, index, require_brace=False):
    """The position of the line that closes the statement starting at `index`.

    A control's modifiers do not sit under its own line -- they hang off the
    end of its closure, and `Button { ... } label: { ... }` has two of those.
    So the chain is only readable once the statement is closed, which is the
    first line that returns to the depth the statement began at.

    `require_brace` is for constructs whose own closure opens lines after the
    modifier that names them -- an alert's does, after a binding whose getter
    and setter open and close closures of their own first, each of which
    returns to the starting depth without the alert having begun.
    """
    start = line_depths[index]
    if not require_brace and "{" not in lines[index][1]:
        return index
    raised = False
    for offset in range(index, len(lines)):
        line = lines[offset][1]
        if line_depths[offset] > start:
            raised = True
        if line_depths[offset] + delta(line) <= start and (raised or not require_brace):
            return offset
    return len(lines) - 1


def chain_from(lines, index):
    """The modifier chain hanging off the line at `index`."""
    chain = [lines[index][1]]
    for offset in range(index + 1, len(lines)):
        text = lines[offset][1].strip()
        if not text or text.startswith("//"):
            continue
        if not text.startswith("."):
            break
        chain.append(text)
    return " ".join(chain)


def system_chrome(lines, line_depths):
    """Line numbers sitting inside a container tvOS draws for itself."""
    covered = set()
    for index, (_, line) in enumerate(lines):
        if not any(name in line for name in SYSTEM_CONTAINERS):
            continue
        end = statement_end(lines, line_depths, index, require_brace=True)
        for offset in range(index, end + 1):
            covered.add(lines[offset][0])
    return covered


def styled(lines, line_depths, index):
    """Whether this control, or anything it sits inside, sets a button style.

    A style on a container reaches every button under it, so a button is bare
    only when nothing from itself outwards dresses it.
    """
    end = statement_end(lines, line_depths, index)
    if any(token in chain_from(lines, end) for token in SAFE):
        return True
    # Outwards: each line that closes to a shallower depth than this control
    # is a container closing around it, and its chain may carry the style.
    depth = line_depths[index]
    for offset in range(end + 1, len(lines)):
        closing = line_depths[offset] + delta(lines[offset][1])
        if closing >= depth:
            continue
        if any(token in chain_from(lines, offset) for token in SAFE):
            return True
        depth = closing
        if depth <= 0:
            break
    return False


def main():
    problems = []
    for path in TARGET_FILES:
        try:
            lines = tvos_lines(open(path).read())
        except FileNotFoundError:
            problems.append(f"{path}: listed in this check but not in the repository")
            continue
        line_depths = depths(lines)
        inside = system_chrome(lines, line_depths)
        for index, (number, line) in enumerate(lines):
            if re.search(r"\bMenu\s*[({]", line) and ".contextMenu" not in line:
                problems.append(
                    f"{path}:{number}: Menu draws tvOS chrome whatever style it is "
                    f"given. Use TVSelectable with a confirmationDialog.\n    {line.strip()}"
                )
                continue
            if not re.search(r"\bButton\s*[({]", line):
                continue
            if number in inside:
                continue  # system chrome draws this one
            if styled(lines, line_depths, index):
                continue
            problems.append(
                f"{path}:{number}: Button with no style, so tvOS will draw its focus "
                f"plate over it. Add .lineupFlatButton() or .lineupButtonStyle().\n"
                f"    {line.strip()}"
            )

    if problems:
        print("tvOS focus check failed:\n")
        for problem in problems:
            print("  " + problem)
        print(f"\n{len(problems)} control(s) would draw a focus plate.")
        return 1
    print("tvOS focus check passed: no control draws its own focus plate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
