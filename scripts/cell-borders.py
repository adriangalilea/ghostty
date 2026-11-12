#!/usr/bin/env python3
"""Experimental Ghostty cell borders. Adapted from Joshka's Rio proof of concept."""

import argparse
import os
import select
import shutil
import sys
import termios
import tty
import time

ESC = "\x1b"
DEFAULT = object()  # The terminal's default background, SGR 49.
BG, PANEL, TEXT, MUTED = "10151d", "212b36", "d3dae3", "8e9cac"
TEAL, RED, GOLD, BLUE = "80c5b7", "d67b88", "e4be78", "8bade2"
TOP_LEFT, TOP_RIGHT, RIGHT_TOP, RIGHT_BOTTOM = 1, 2, 4, 8
BOTTOM_LEFT, BOTTOM_RIGHT, LEFT_TOP, LEFT_BOTTOM = 16, 32, 64, 128
H_LEFT, H_RIGHT, V_TOP, V_BOTTOM = 256, 512, 1024, 2048
TOP, RIGHT = TOP_LEFT | TOP_RIGHT, RIGHT_TOP | RIGHT_BOTTOM
BOTTOM, LEFT = BOTTOM_LEFT | BOTTOM_RIGHT, LEFT_TOP | LEFT_BOTTOM
HORIZONTAL, VERTICAL = H_LEFT | H_RIGHT, V_TOP | V_BOTTOM
OUTLINE, ALL = TOP | RIGHT | BOTTOM | LEFT, 4095
PROTOCOL = "ghostty"


def encode(operation, *fields):
    if PROTOCOL == "rio":
        body = ";".join(map(str, ("rio-border", 1, operation, *fields)))
        return f"{ESC}_{body}{ESC}\\"
    body = ";".join(map(str, ("cell-border", operation, *fields)))
    return f"{ESC}P1+b{body}{ESC}\\"


def wire_mask(mask):
    if PROTOCOL != "rio":
        return mask
    result = 0
    for full, rio in ((TOP, 1), (RIGHT, 2), (BOTTOM, 4), (LEFT, 8)):
        part = mask & full
        if part and part != full:
            raise ValueError("Rio's prototype has no half outer edges")
        if part:
            result |= rio
    for half, rio in ((H_LEFT, 64), (H_RIGHT, 128), (V_TOP, 256), (V_BOTTOM, 512)):
        if mask & half:
            result |= rio
    return result


def clear(row, col, mask=ALL, rows=1, cols=1):
    return move(row, col) + encode("clear", wire_mask(mask), rows, cols)



def rgb(color):
    return ";".join(str(int(color[i:i + 2], 16)) for i in (0, 2, 4))


def move(row, col):
    return f"{ESC}[{row};{col}H"


def border(row, col, mask, width=16, color=TEAL, placement=0, layer=1,
           rows=1, cols=1, style=None):
    """Paint selected strokes on each cell in a cursor-relative rectangle."""
    extra = (f"style={style}",) if style else ()
    return move(row, col) + encode("set", wire_mask(mask), width, color,
                                  placement, layer, rows, cols, *extra)


# Joint flags: one quadrant of each joint point inside the cell.
CORNER_TL, CORNER_TR, CORNER_BR, CORNER_BL = 1, 2, 4, 8
CENTER_TR, CENTER_BR, CENTER_BL, CENTER_TL = 16, 32, 64, 128


def round_joints(row, col, joints, rows=1, cols=1, outside=None, radius=None):
    extra = (f"outside={outside}",) if outside else ()
    extra += (f"radius={radius}",) if radius else ()
    return move(row, col) + encode("round", joints, rows, cols, *extra)


def outline(row, col, rows, cols, color=TEAL, width=16, placement=0, layer=1,
            style=None, rounded=False, outside=None, radius=None):
    """Four strips make an outer rectangle, without bordering its interior cells."""
    parts = [
        border(row, col, TOP, width, color, placement, layer, cols=cols, style=style),
        border(row + rows - 1, col, BOTTOM, width, color, placement, layer, cols=cols, style=style),
        border(row, col, LEFT, width, color, placement, layer, rows=rows, style=style),
        border(row, col + cols - 1, RIGHT, width, color, placement, layer, rows=rows, style=style),
    ]
    if rounded:
        right, bottom = col + cols - 1, row + rows - 1
        parts += [round_joints(row, col, CORNER_TL, outside=outside, radius=radius),
                  round_joints(row, right, CORNER_TR, outside=outside, radius=radius),
                  round_joints(bottom, right, CORNER_BR, outside=outside, radius=radius),
                  round_joints(bottom, col, CORNER_BL, outside=outside, radius=radius)]
    return "".join(parts)


def center_box(row, col, rows, cols, color=TEAL, width=16, style=None, rounded=False,
               outside=None):
    """A rectangle on the centrelines of its perimeter cells, like box-drawing text."""
    right, bottom = col + cols - 1, row + rows - 1
    parts = [
        border(row, col, H_RIGHT | V_BOTTOM, width, color, style=style),
        border(row, right, H_LEFT | V_BOTTOM, width, color, style=style),
        border(bottom, col, H_RIGHT | V_TOP, width, color, style=style),
        border(bottom, right, H_LEFT | V_TOP, width, color, style=style),
        border(row, col + 1, HORIZONTAL, width, color, cols=cols - 2, style=style),
        border(bottom, col + 1, HORIZONTAL, width, color, cols=cols - 2, style=style),
        border(row + 1, col, VERTICAL, width, color, rows=rows - 2, style=style),
        border(row + 1, right, VERTICAL, width, color, rows=rows - 2, style=style),
    ]
    if rounded:
        parts += [round_joints(row, col, CENTER_BR, outside=outside),
                  round_joints(row, right, CENTER_BL, outside=outside),
                  round_joints(bottom, col, CENTER_TR, outside=outside),
                  round_joints(bottom, right, CENTER_TL, outside=outside)]
    return "".join(parts)



def half_outline(row, col, text_width, color=TEAL, width=16):
    """Outline a three-row block shape at the centers of its perimeter cells."""
    right = col + text_width + 1
    return "".join((
        border(row, col, H_RIGHT | V_BOTTOM, width, color),
        border(row, right, H_LEFT | V_BOTTOM, width, color),
        border(row + 2, col, H_RIGHT | V_TOP, width, color),
        border(row + 2, right, H_LEFT | V_TOP, width, color),
        border(row, col + 1, HORIZONTAL, width, color, cols=text_width),
        border(row + 2, col + 1, HORIZONTAL, width, color, cols=text_width),
        border(row + 1, col, VERTICAL, width, color),
        border(row + 1, right, VERTICAL, width, color),
    ))


def scene(enabled=True):
    output = [f"{ESC}[0m{ESC}[48;2;{rgb(BG)}m{ESC}[2J{ESC}[H"]
    borders = []

    def text(row, col, value, fg=TEXT, bg=BG):
        output.append(move(row, col) + f"{ESC}[38;2;{rgb(fg)};48;2;{rgb(bg)}m" + value)

    def fill(row, col, height, width, color):
        for y in range(row, row + height):
            text(y, col, " " * width, bg=color)

    text(1, 3, "CELL BORDERS / EXPERIMENT", TEAL)
    text(1, 55, "cell edges / centerline segments", MUTED)
    text(3, 3, "Thin lines, full cells. Text keeps its own foreground.", MUTED)
    fill(5, 3, 19, 74, PANEL)
    borders.append(outline(5, 3, 19, 74, BLUE))
    text(6, 5, "Abandon this change?", TEAL, PANEL)
    text(8, 5, "qpvuntsm", "c49be0", PANEL)
    text(8, 16, "Keep focus when closing a preview", bg=PANEL)
    text(10, 5, "Changes to abandon (3 files)", bg=PANEL)
    for row, status, path, delta, color in (
        (12, "D", "README.md", "+0  -3", RED),
        (13, "M", "crates/jk-tui/src/chrome.rs", "+1  -1", GOLD),
        (14, "A", "docs/tui-design.md", "+5  -0", TEAL),
    ):
        text(row, 5, status, color, PANEL)
        text(row, 8, path, bg=PANEL)
        text(row, 64, delta, color, PANEL)
    text(16, 5, "Recover with Undo in the action menu.", MUTED, PANEL)
    for col, width, label, color, background in (
        (5, 18, "View diff", MUTED, "2b3745"),
        (26, 18, "Cancel", TEAL, "263e41"),
        (47, 28, "Abandon change", RED, "422e38"),
    ):
        fill(18, col, 3, width, background)
        text(19, col + (width - len(label)) // 2, label, color, background)
        borders.append(outline(18, col, 3, width, color))
    text(22, 5, "Tab / arrows choose    Enter activate    Esc cancel", MUTED, PANEL)

    text(25, 3, "ACTIVE FIELD", TEAL)
    text(25, 41, "INACTIVE FIELD", MUTED)
    fill(26, 3, 3, 36, PANEL)
    fill(26, 41, 3, 36, PANEL)
    text(27, 5, "Search changes...", TEXT, PANEL)
    text(27, 43, "Filter by author", MUTED, PANEL)
    borders.extend((outline(26, 3, 3, 36, TEAL), outline(26, 41, 3, 36, MUTED)))

    text(30, 3, "ACTIVE / UNDERLINE ONLY", TEAL)
    text(30, 41, "INACTIVE / UNDERLINE ONLY", MUTED)
    fill(31, 3, 3, 36, PANEL)
    fill(31, 41, 3, 36, PANEL)
    text(32, 5, "Search changes...", TEXT, PANEL)
    text(32, 43, "Filter by author", MUTED, PANEL)
    borders.extend((border(33, 3, BOTTOM, color=TEAL, cols=36),
                    border(33, 41, BOTTOM, color=MUTED, cols=36)))

    text(35, 3, "QUADRANTS", MUTED)
    text(35, 20, "WIDTH 4 / 16 / 32", MUTED)
    text(35, 46, "INSIDE / CENTERED", MUTED)
    text(35, 68, "BELOW / ABOVE", MUTED)
    # A colored center cross adds a third color to each two-color block cell.
    text(37, 4, "▚▞▚▞", BLUE, "34453f")
    text(38, 4, "▞▚▞▚", BLUE, "34453f")
    borders.append(border(37, 4, HORIZONTAL | VERTICAL, color=GOLD, rows=2, cols=4))
    borders.append(outline(37, 4, 2, 4, RED))
    for col, width in ((21, 4), (27, 16), (33, 32)):
        fill(37, col, 2, 4, PANEL)
        borders.append(outline(37, col, 2, 4, TEAL, width))
    for col, placement in ((47, 0), (57, 1)):
        fill(37, col, 2, 6, "344151")
        borders.append(outline(37, col, 2, 6, GOLD, 32, placement))
    for col, layer in ((69, 0), (76, 1)):
        text(37, col, "████", BLUE, PANEL)
        borders.append(border(37, col, HORIZONTAL, 32, RED, layer=layer, cols=4))
    text(40, 3, "b: borders  h: blocks  j: joins  p: placement  c: colors  q: quit  " +
         ("BORDERS ON" if enabled else "BORDERS OFF"), MUTED)
    # Painting is deliberately last: subsequent text writes clear cell borders.
    if enabled:
        output.extend(borders)
    output.append(f"{ESC}[0m" + move(41, 1))
    return "".join(output)



def placement_scene(enabled=True, stroke_width=32):
    """Compare placement against fixed cell boundaries at several button sizes."""
    surround, button_bg = "303a48", "305a73"
    output = [f"{ESC}[0m{ESC}[48;2;{rgb(BG)}m{ESC}[2J{ESC}[H"]
    borders = []

    def text(row, col, value, fg=TEXT, bg=BG):
        output.append(move(row, col) + f"{ESC}[38;2;{rgb(fg)};48;2;{rgb(bg)}m" + value)

    def fill(row, col, height, width, color):
        for y in range(row, row + height):
            text(y, col, " " * width, bg=color)

    text(1, 3, "CELL EDGE / PLACEMENT", TEAL)
    text(3, 3, "Same button sizes and stroke widths on both sides.", MUTED)
    for panel_col, placement, title, description in (
        (3, 0, "INSIDE", "Stroke stays on the blue fill."),
        (41, 1, "CENTERED", "Stroke straddles blue and slate."),
    ):
        text(5, panel_col, title, GOLD)
        text(6, panel_col, description, MUTED)
        for row, height, width, label, caption in (
            (10, 1, 2, "OK", "1 row / 2 columns: no padding"),
            (15, 3, 16, "Save", "3 rows / 16 columns: padded"),
            (22, 5, 28, "Apply changes", "5 rows / 28 columns: spacious"),
        ):
            text(row - 2, panel_col, caption, MUTED)
            fill(row - 1, panel_col, height + 2, 36, surround)
            col = panel_col + (36 - width) // 2
            fill(row, col, height, width, button_bg)
            text(row + height // 2, col + (width - len(label)) // 2,
                 label, TEXT, button_bg)
            # Adjacent text and the background transition expose outward spill.
            text(row - 1, col, "above", MUTED, surround)
            text(row + height, col, "below", MUTED, surround)
            text(row + height // 2, col - 2, "L>", MUTED, surround)
            text(row + height // 2, col + width, "<R", MUTED, surround)
            borders.append(outline(row, col, height, width, GOLD,
                                   stroke_width, placement))
    text(29, 3, "Blue = button cells. Slate = neighboring cells. Gold = border.", MUTED)
    text(31, 3, f"w: stroke width {stroke_width}/256 cell width (same on both sides)", GOLD)
    text(32, 3, "Small widths may both round to 1 pixel; zoom the font for a closer look.", MUTED)
    text(33, 3, "Toggle b to reveal the original blue/slate boundary.", MUTED)
    text(35, 3, "b: borders  h: blocks  j: joins  p: overview  c: colors  w: width  q: quit", MUTED)
    if enabled:
        output.extend(borders)
    output.append(f"{ESC}[0m" + move(36, 1))
    return "".join(output)



def brightness_scene(enabled=True):
    """Compare border, fill, and per-edge brightness without changing button size."""
    output = [f"{ESC}[0m{ESC}[48;2;{rgb(BG)}m{ESC}[2J{ESC}[H"]
    borders = []

    def text(row, col, value, fg=TEXT, bg=BG):
        output.append(move(row, col) + f"{ESC}[38;2;{rgb(fg)};48;2;{rgb(bg)}m" + value)

    def button(row, col, label, background):
        for y in range(row, row + 3):
            text(y, col, " " * 22, bg=background)
        text(row + 1, col + (22 - len(label)) // 2, label, bg=background)

    text(1, 3, "BUTTONS / COLOR BRIGHTNESS", TEAL)
    text(3, 3, "Same hue, size, and text color. Compare one change at a time.", MUTED)
    text(7, 3, "BORDER BRIGHTNESS / fixed fill", MUTED)
    text(16, 3, "FILL BRIGHTNESS / fixed border", MUTED)
    text(25, 3, "EDGE BRIGHTNESS / fixed fill", MUTED)
    for col, label, edge, background in (
        (3, "Dim", "3c625b", "182823"),
        (29, "Medium", "679f91", "294438"),
        (55, "Bright", "a4ebd7", "3d6553"),
    ):
        button(9, col, label, PANEL)
        borders.append(outline(9, col, 3, 22, edge))
        button(18, col, label, background)
        borders.append(outline(18, col, 3, 22, TEAL))
    for col, label, top, bottom in (
        (3, "Flat", "679f91", "679f91"),
        (29, "Raised", "a4ebd7", "3c625b"),
        (55, "Pressed", "3c625b", "a4ebd7"),
    ):
        button(27, col, label, PANEL)
        borders.extend((
            border(27, col, TOP, color=top, cols=22),
            border(27, col, LEFT, color=top, rows=3),
            border(29, col, BOTTOM, color=bottom, cols=22),
            border(27, col + 21, RIGHT, color=bottom, rows=3),
        ))
    text(13, 3, "Only the outline changes: subdued, normal, emphasized.", MUTED)
    text(22, 3, "Only the background changes; borders and labels stay constant.", MUTED)
    text(32, 3, "Different edge colors suggest depth without extra characters.", MUTED)
    text(34, 3, "NO PADDING / borders on the text cells themselves", MUTED)
    for col, label, edge in (
        (3, "Dim", "3c625b"),
        (29, "Medium", "679f91"),
        (55, "Bright", "a4ebd7"),
    ):
        text(36, col, "Choose ", MUTED)
        text(36, col + 7, label, TEXT, PANEL)
        text(36, col + 7 + len(label), " now", MUTED)
        borders.append(outline(36, col + 7, 1, len(label), edge))
    text(38, 3, "One row, exactly the label's width. No added spaces or border characters.", MUTED)
    text(40, 3, "b: borders  h: blocks  j: joins  c: overview  p: placement  q: quit", MUTED)
    if enabled:
        output.extend(borders)
    output.append(f"{ESC}[0m" + move(41, 1))
    return "".join(output)



def block_scene(enabled=True, stroke_width=16):
    """Use quadrant and half-block fills, with borders on their internal edges."""
    output = [f"{ESC}[0m{ESC}[48;2;{rgb(BG)}m{ESC}[2J{ESC}[H"]
    borders = []

    def text(row, col, value, fg=TEXT, bg=BG):
        output.append(move(row, col) + f"{ESC}[38;2;{rgb(fg)};48;2;{rgb(bg)}m" + value)

    text(1, 3, "HALF-CELL BUTTONS / CENTERLINE BORDERS", TEAL)
    text(3, 3, "Same text. Right-hand fills stop halfway through their perimeter cells.", MUTED)
    text(5, 3, "FULL-CELL PADDING", MUTED)
    text(5, 41, "HALF-BLOCKS + QUADRANTS", GOLD)
    for row, label, fill_color, edge in (
        (9, "Cancel", "294438", TEAL),
        (16, "Apply changes", "344151", BLUE),
        (23, "Filter by author", PANEL, GOLD),
    ):
        text(row - 2, 3, "Full outline", MUTED)
        text(row - 2, 41, "Centerlines follow the fill", MUTED)
        # Left: one full row above/below and two columns beside the text.
        for y in range(row, row + 3):
            text(y, 5, " " * (len(label) + 4), bg=fill_color)
        text(row + 1, 7, label, bg=fill_color)
        borders.append(outline(row, 5, 3, len(label) + 4, edge, stroke_width))
        # Right: corners fill only the inward quadrant; side cells fill one half.
        # Foreground paints blocks; label foreground and border are independent colors.
        col = 43
        text(row, col, "▗" + "▄" * len(label) + "▖", fill_color)
        text(row + 1, col, "▐", fill_color)
        text(row + 1, col + 1, label, TEXT, fill_color)
        text(row + 1, col + len(label) + 1, "▌", fill_color)
        text(row + 2, col, "▝" + "▀" * len(label) + "▘", fill_color)
        borders.append(half_outline(row, col, len(label), edge, stroke_width))
        text(row + 1, col + len(label) + 3, "adjacent text", MUTED)
    text(29, 3, "▗ ▖ ▝ ▘ shape the corners; ▄ ▀ ▐ ▌ shape the sides.", MUTED)
    text(31, 3, "Borders follow those half-cell edges, not the outer cell rectangle.", MUTED)
    text(32, 3, "Two half-length centerlines join at each corner, without cross-shaped tails.", MUTED)
    text(34, 3, f"w: width {stroke_width}/256    b: hide borders to inspect the block shapes", GOLD)
    text(40, 3, "h: overview    j: junctions    p: placement    c: colors    q / Esc: quit", MUTED)
    if enabled:
        output.extend(borders)
    output.append(f"{ESC}[0m" + move(41, 1))
    return "".join(output)



def junction_scene(enabled=True, stroke_width=16):
    """Offset header, content, and status dividers on shared half-cell boundaries."""
    output = [f"{ESC}[0m{ESC}[48;2;{rgb(BG)}m{ESC}[2J{ESC}[H"]
    borders = []
    status_bg = "263e41"

    def text(row, col, value, fg=TEXT, bg=BG):
        output.append(move(row, col) + f"{ESC}[38;2;{rgb(fg)};48;2;{rgb(bg)}m" + value)

    text(1, 3, "T-JUNCTIONS / OFFSET BAR DIVIDERS", TEAL)
    text(3, 3, "Header, content, and status sections need not share column boundaries.", MUTED)
    text(5, 3, "Each divider stops at a horizontal centerline; none crosses the next band.", MUTED)
    for row in range(8, 11):
        text(row, 3, " " * 74, bg=PANEL)
    # The shared row carries two backgrounds, split at its horizontal center.
    text(11, 3, "▀" * 74, PANEL, BG)
    text(23, 3, "▀" * 74, BG, status_bg)
    for row in range(24, 27):
        text(row, 3, " " * 74, bg=status_bg)
    text(9, 5, "PROJECT / rio", TEAL, PANEL)
    text(9, 27, "BRANCH / prototype", TEXT, PANEL)
    text(9, 53, "VIEW / changes", TEXT, PANEL)
    text(14, 5, "FILES", MUTED)
    text(16, 5, "M  cell-borders.py", TEXT)
    text(18, 5, "M  border_protocol.rs", TEXT)
    text(14, 37, "PREVIEW", MUTED)
    text(16, 37, "Header ends at 24 / 50")
    text(18, 37, "Content at 34 / 60")
    text(14, 63, "DETAILS", MUTED)
    text(16, 63, "3 changes")
    text(18, 63, "Ready", TEAL)
    text(25, 5, "NORMAL", TEAL, status_bg)
    text(25, 23, "3 files / no conflicts", TEXT, status_bg)
    text(25, 57, "Ln 12 / Col 4", TEXT, status_bg)
    borders.append(outline(8, 3, 19, 74, BLUE, stroke_width))
    for row in (11, 23):
        borders.append(border(row, 3, HORIZONTAL, stroke_width, BLUE, cols=74))
    # A full horizontal line + just one vertical arm makes a T, not a cross.
    for col in (24, 50):
        borders.append(border(8, col, VERTICAL, stroke_width, BLUE, rows=3))
        borders.append(border(11, col, HORIZONTAL | V_TOP, stroke_width, BLUE))
    for col in (34, 60):
        borders.append(border(11, col, HORIZONTAL | V_BOTTOM, stroke_width, BLUE))
        borders.append(border(12, col, VERTICAL, stroke_width, BLUE, rows=11))
        borders.append(border(23, col, HORIZONTAL | V_TOP, stroke_width, BLUE))
    for col in (20, 54):
        borders.append(border(23, col, HORIZONTAL | V_BOTTOM, stroke_width, BLUE))
        borders.append(border(24, col, VERTICAL, stroke_width, BLUE, rows=3))
    text(29, 3, "At each shared row: top arms finish one band; bottom arms start another.", MUTED)
    text(31, 3, "Upward T: horizontal + top arm (272). Downward T: horizontal + bottom (528).", MUTED)
    text(33, 3, "The ▀ cells put the background transition exactly under the shared line.", MUTED)
    text(35, 3, f"w: stroke width {stroke_width}/256    b: toggle borders", GOLD)
    text(40, 3, "j: overview    h: blocks    p: placement    c: colors    q: quit", MUTED)
    if enabled:
        output.extend(borders)
    output.append(f"{ESC}[0m" + move(41, 1))
    return "".join(output)


def styles_scene(enabled=True, stroke_width=32):
    """Line styles, rounded corners, forks and double-line junctions."""
    output = [f"{ESC}[0m{ESC}[48;2;{rgb(BG)}m{ESC}[2J{ESC}[H"]
    borders = []
    double = stroke_width  # Double lines are at least three pixels anyway.

    def text(row, col, value, fg=TEXT, bg=BG):
        background = "49" if bg is DEFAULT else f"48;2;{rgb(bg)}"
        output.append(move(row, col) + f"{ESC}[38;2;{rgb(fg)};{background}m" + value)

    text(1, 3, "LINE STYLES / JOINTS", TEAL)
    text(1, 50, "style=  round  pen-round", MUTED)

    text(3, 3, "SOLID", MUTED)
    text(3, 22, "DOUBLE", MUTED)
    text(3, 41, "DASHED", MUTED)
    text(3, 60, "DOTTED", MUTED)
    for col, style, color in ((3, "solid", TEAL), (22, "double", BLUE),
                              (41, "dashed", GOLD), (60, "dotted", RED)):
        width = double if style == "double" else stroke_width
        borders.append(outline(4, col, 4, 17, color, width, style=style))
        text(5, col + 2, f"inside {width}", MUTED)
        borders.append(center_box(9, col, 4, 17, color, width, style=style))
        text(10, col + 2, "centrelines", MUTED)

    text(14, 3, "ROUNDED CORNERS", MUTED)
    for col, style, color in ((3, "solid", TEAL), (22, "double", BLUE),
                              (41, "dashed", GOLD), (60, "dotted", RED)):
        width = double if style == "double" else stroke_width
        borders.append(outline(15, col, 4, 17, color, width, style=style, rounded=True))
        borders.append(center_box(20, col, 4, 17, color, width, style=style, rounded=True))
    text(16, 5, "round 1-8", MUTED)
    text(21, 5, "round 16+", MUTED)

    text(25, 3, "FORKS", MUTED)
    # A line with a stem: square T, one-sided fork, split, and filleted cross.
    for col, joints, label in ((3, 0, "square"), (17, CENTER_BR, "fork 32"),
                               (31, CENTER_BR | CENTER_BL, "split 96"),
                               (45, CENTER_BR | CENTER_BL | CENTER_TL | CENTER_TR, "cross 240")):
        borders.append(border(27, col, HORIZONTAL, stroke_width, TEAL, cols=11))
        mid = col + 5
        stem = V_BOTTOM | (V_TOP if joints == 240 else 0)
        borders.append(border(27, mid, HORIZONTAL | stem, stroke_width, TEAL))
        borders.append(border(28, mid, VERTICAL, stroke_width, TEAL, rows=2))
        if joints == 240:
            borders.append(border(26, mid, VERTICAL, stroke_width, TEAL))
        if joints:
            borders.append(round_joints(27, mid, joints))
        text(30, col + 2, label, MUTED)
    # A rounded tree, like a file browser.
    borders.append(border(26, 62, VERTICAL, stroke_width, GOLD, rows=4))
    for row in (27, 29):
        borders.append(border(row, 62, VERTICAL | H_RIGHT, stroke_width, GOLD))
        borders.append(border(row, 63, HORIZONTAL, stroke_width, GOLD))
        borders.append(round_joints(row, 62, CENTER_TR))
        text(row, 65, "child", TEXT)
    borders.append(border(30, 62, V_TOP | H_RIGHT, stroke_width, GOLD))
    borders.append(border(30, 63, HORIZONTAL, stroke_width, GOLD))
    borders.append(round_joints(30, 62, CENTER_TR))
    text(30, 65, "last", TEXT)

    text(32, 3, "DOUBLE JUNCTIONS", MUTED)
    # A double grid: corners, tees and a cross keep their interiors open.
    top, left, rows, cols = 33, 3, 6, 25
    borders.append(center_box(top, left, rows, cols, BLUE, double, style="double"))
    mid_row, mid_col = top + 3, left + 12
    borders.append(border(mid_row, left + 1, HORIZONTAL, double, BLUE, cols=cols - 2, style="double"))
    borders.append(border(top + 1, mid_col, VERTICAL, double, BLUE, rows=rows - 2, style="double"))
    borders.append(border(mid_row, left, VERTICAL | H_RIGHT, double, BLUE, style="double"))
    borders.append(border(mid_row, left + cols - 1, VERTICAL | H_LEFT, double, BLUE, style="double"))
    borders.append(border(top, mid_col, HORIZONTAL | V_BOTTOM, double, BLUE, style="double"))
    borders.append(border(top + rows - 1, mid_col, HORIZONTAL | V_TOP, double, BLUE, style="double"))
    borders.append(border(mid_row, mid_col, HORIZONTAL | VERTICAL, double, BLUE, style="double"))
    # Mixed: single stems meeting a double line stop at its nearer line.
    borders.append(border(34, 31, HORIZONTAL, double, BLUE, cols=24, style="double"))
    for col in (35, 43, 51):
        borders.append(border(35, col, VERTICAL, stroke_width, TEAL, rows=3))
        borders.append(border(34, col, V_BOTTOM, stroke_width, TEAL))
    borders.append(border(38, 31, HORIZONTAL, stroke_width, TEAL, cols=24))
    for col in (39, 47):
        borders.append(border(38, col, HORIZONTAL | V_TOP, stroke_width, TEAL))
        borders.append(border(36, col, VERTICAL, double, BLUE, rows=2, style="double"))
    text(36, 58, "single meets", MUTED)
    text(37, 58, "double: stops at", MUTED)
    text(38, 58, "the nearer line", MUTED)
    # Panels on the terminal's default background: the rounded corners cut
    # the panel colour off only with outside=default.
    panel = "305a73"
    output.append(f"{ESC}[0m")
    for row in range(40, 52):
        output.append(move(row, 1) + f"{ESC}[2K")
    text(40, 3, "OUTSIDE FILL (default background)", MUTED, DEFAULT)
    for col, outside, label in ((3, None, "no outside="), (23, "default", "outside=default")):
        for row in range(41, 45):
            text(row, col, " " * 18, bg=panel)
        text(42, col + 2, label, TEXT, panel)
        borders.append(outline(41, col, 4, 18, TEAL, stroke_width, rounded=True, outside=outside))
    # Centred strokes straddle the panel's outer cell edges, as an app
    # outlining its panel would draw them.
    for col, outside in ((43, None), (63, "default")):
        for row in range(41, 45):
            text(row, col, " " * 16, bg=panel)
        text(42, col + 2, "centre" if outside is None else "centre+fill", TEXT, panel)
        borders.append(outline(41, col, 4, 16, TEAL, stroke_width, placement=1,
                               rounded=True, outside=outside))
    text(46, 3, "RADIUS (1/256 of cell width; unset = terminal default)", MUTED, DEFAULT)
    for col, radius in ((3, 64), (23, None), (43, 128), (63, 256)):
        for row in range(47, 50):
            text(row, col, " " * 16, bg=panel)
        text(48, col + 2, f"radius={radius or 'unset'}", TEXT, panel)
        borders.append(outline(47, col, 3, 16, TEAL, stroke_width, rounded=True,
                               outside="default", radius=radius))
    text(51, 3, f"w: stroke width {stroke_width}/256    b: toggle borders", GOLD, DEFAULT)
    if enabled:
        output.extend(borders)
    output.append(f"{ESC}[0m" + move(52, 1))
    return "".join(output)


def halves_scene(enabled=True, stroke_width=16):
    output = [f"{ESC}[0m{ESC}[48;2;{rgb(BG)}m{ESC}[2J{ESC}[H"]
    lines = []

    def text(row, col, value, fg=TEXT, bg=BG):
        output.append(move(row, col) + f"{ESC}[38;2;{rgb(fg)};48;2;{rgb(bg)}m" + value)

    text(1, 3, "HALF EDGES / QUADRANT OUTLINES", TEAL)
    text(3, 3, "Each small filled quadrant has four independently addressable sides.", MUTED)
    quadrants = (
        ("▘", TOP_LEFT | LEFT_TOP | H_LEFT | V_TOP, "top left"),
        ("▝", TOP_RIGHT | RIGHT_TOP | H_RIGHT | V_TOP, "top right"),
        ("▖", BOTTOM_LEFT | LEFT_BOTTOM | H_LEFT | V_BOTTOM, "bottom left"),
        ("▗", BOTTOM_RIGHT | RIGHT_BOTTOM | H_RIGHT | V_BOTTOM, "bottom right"),
    )
    for row, (glyph, mask, label) in zip((7, 12, 17, 22), quadrants):
        text(row, 3, label, MUTED)
        for i in range(12):
            col = 22 + i * 4
            text(row, col, glyph, BLUE, PANEL)
            lines.append(border(row, col, mask, stroke_width, GOLD))
    text(27, 3, "FULL SIDES ARE STILL EASY", TEAL)
    text(29, 5, " TOP ", bg=PANEL)
    text(29, 25, " TOP | BOTTOM ", bg=PANEL)
    text(29, 53, " OUTLINE ", bg=PANEL)
    lines.extend((border(29, 5, TOP, stroke_width, TEAL, cols=5),
                  border(29, 25, TOP | BOTTOM, stroke_width, TEAL, cols=14),
                  outline(29, 53, 1, 9, TEAL, stroke_width)))
    text(34, 3, "b: borders   w: width   e: overview   h: block buttons   q: quit", MUTED)
    if enabled:
        output.extend(lines)
    return "".join(output) + f"{ESC}[0m" + move(36, 1)


def live_scene():
    """An incremental repaint experiment; keystrokes do not redraw the screen."""
    value = "Type here"
    repair = True
    popup = False
    field_row, field_col, field_width = 10, 7, 30

    def field():
        result = move(field_row, field_col) + f"{ESC}[38;2;{rgb(TEXT)};48;2;{rgb(PANEL)}m"
        result += value[:field_width].ljust(field_width)
        if repair:
            result += outline(field_row, field_col, 1, field_width, TEAL)
        return result

    def status():
        return (move(15, 3) + f"{ESC}[0m{ESC}[38;2;{rgb(MUTED)}m{ESC}[48;2;{rgb(BG)}m"
                + "Repaint after text: " + ("ON " if repair else "OFF")
                + "    Tab: toggle   Ctrl+P: popup   Esc: overview   Ctrl+C: quit")

    sys.stdout.write(f"{ESC}[0m{ESC}[48;2;{rgb(BG)}m{ESC}[2J{ESC}[H")
    sys.stdout.write(move(2, 3) + "INCREMENTAL TEXT / BORDER REPAINT")
    sys.stdout.write(move(5, 3) + "Typing overwrites cells. Toggle repaint to see their borders disappear.")
    sys.stdout.write(field() + status())
    sys.stdout.flush()
    while True:
        key = sys.stdin.read(1)
        if key in (ESC, ""):
            return
        if key == "\t":
            repair = not repair
        elif key == "\x10":
            popup = not popup
            if popup:
                sys.stdout.write(move(9, 12) + f"{ESC}[38;2;{rgb(BG)};48;2;{rgb(BLUE)}m" + " " * 20)
                sys.stdout.write(move(10, 12) + "    A small popup   ")
                sys.stdout.write(move(11, 12) + " " * 20)
                sys.stdout.write(outline(9, 12, 3, 20, GOLD))
            else:
                for row in (9, 10, 11):
                    sys.stdout.write(move(row, 12) + f"{ESC}[48;2;{rgb(BG)}m" + " " * 20)
                sys.stdout.write(field())
            sys.stdout.flush()
            continue
        elif key in ("\x7f", "\b"):
            value = value[:-1]
        elif key.isprintable():
            value = (value + key)[-field_width:]
        if not popup:
            sys.stdout.write(field())
        sys.stdout.write(status())
        sys.stdout.flush()


def probe():
    sys.stdout.write(encode("q"))
    sys.stdout.flush()
    if not select.select([sys.stdin], [], [], 0.4)[0]:
        return False
    response = os.read(sys.stdin.fileno(), 4096)
    # Read remaining fragments without consuming any ordinary user input later.
    while b"\x1b\\" not in response and select.select([sys.stdin], [], [], 0.1)[0]:
        response += os.read(sys.stdin.fileno(), 4096)
    return b"cell-border;ok;" in response


def main():
    global PROTOCOL
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol", choices=("ghostty", "rio"), default="ghostty")
    parser.add_argument("--no-query", action="store_true", help="skip capability detection")
    parser.add_argument("--emit", action="store_true",
                        help="write one frame; no alternate screen, input, or cleanup")
    views = parser.add_mutually_exclusive_group()
    views.add_argument("--placement", action="store_true",
                        help="start with the detailed inside/centered comparison")
    views.add_argument("--colors", action="store_true",
                       help="start with the button brightness comparison")
    views.add_argument("--blocks", action="store_true",
                       help="show quadrant/half-block shapes with centerline borders")
    views.add_argument("--junctions", action="store_true",
                       help="show offset header/status dividers joined by centerline Ts")
    views.add_argument("--halves", action="store_true", help="half outer edges around quadrants")
    views.add_argument("--styles", action="store_true",
                       help="line styles, rounded corners, forks and double junctions")
    views.add_argument("--live", action="store_true", help="incremental text and popup experiment")
    args = parser.parse_args()
    PROTOCOL = args.protocol
    if (args.halves or args.styles) and PROTOCOL == "rio":
        parser.error("half outer edges require the Ghostty prototype")
    if args.live and args.emit:
        parser.error("the live experiment needs input")
    view = "overview"
    if args.halves:
        view = "halves"
    elif args.live:
        view = "live"
    elif args.placement:
        view = "placement"
    elif args.colors:
        view = "colors"
    elif args.blocks:
        view = "blocks"
    elif args.junctions:
        view = "junctions"
    elif args.styles:
        view = "styles"
    if args.emit:
        render = {"overview": scene, "placement": placement_scene,
                  "colors": brightness_scene, "blocks": block_scene,
                  "junctions": junction_scene, "halves": halves_scene,
                  "styles": styles_scene}
        sys.stdout.write(render[view]())
        return
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error("interactive mode needs a terminal; use --emit for a capture")
    # A new macOS window can start its PTY before its first layout updates
    # the size. Briefly allow that initial SIGWINCH before checking the gallery.
    for _ in range(20):
        size = shutil.get_terminal_size()
        if size.columns >= 88 and size.lines >= 42:
            break
        time.sleep(0.05)
    else:
        parser.error("please resize to at least 88 columns by 42 rows (or use --emit)")
    old = termios.tcgetattr(sys.stdin.fileno())
    entered = False
    try:
        tty.setcbreak(sys.stdin.fileno())
        if not args.no_query and not probe():
            parser.error("no border reply; run inside the prototype, or use --no-query")
        sys.stdout.write(f"{ESC}[?1049h{ESC}[?25l")
        entered = True
        enabled = True
        widths = (4, 16, 32, 48, 64)
        width_index = 2
        while True:
            if view == "live":
                live_scene()
                view = "overview"
            if view == "halves":
                frame = halves_scene(enabled, widths[width_index])
            elif view == "placement":
                frame = placement_scene(enabled, widths[width_index])
            elif view == "junctions":
                frame = junction_scene(enabled, widths[width_index])
            elif view == "styles":
                frame = styles_scene(enabled, widths[width_index])
            elif view == "blocks":
                frame = block_scene(enabled, widths[width_index])
            elif view == "colors":
                frame = brightness_scene(enabled)
            else:
                frame = scene(enabled)
            footer = 47 if view == "styles" else 41
            sys.stdout.write(frame + move(footer, 3) + f"{ESC}[0m{ESC}[38;2;{rgb(MUTED)}m"
                             + "b: borders  p: placement  c: colors  h: blocks  j: junctions  e: halves  s: styles  l: live")
            sys.stdout.flush()
            key = sys.stdin.read(1)
            if key in ("q", "Q", ESC, ""):
                break
            if key.lower() == "b":
                enabled = not enabled
            elif key.lower() == "p":
                view = "overview" if view == "placement" else "placement"
            elif key.lower() == "c":
                view = "overview" if view == "colors" else "colors"
            elif key.lower() == "h":
                view = "overview" if view == "blocks" else "blocks"
            elif key.lower() == "j":
                view = "overview" if view == "junctions" else "junctions"
            elif key.lower() == "e" and PROTOCOL == "ghostty":
                view = "overview" if view == "halves" else "halves"
            elif key.lower() == "s" and PROTOCOL == "ghostty":
                view = "overview" if view == "styles" else "styles"
            elif key.lower() == "l":
                view = "live"
            elif key.lower() == "w":
                width_index = (width_index + 1) % len(widths)
    except KeyboardInterrupt:
        pass
    finally:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old)
        if entered:
            sys.stdout.write(f"{ESC}[0m{ESC}[?25h{ESC}[?1049l")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
