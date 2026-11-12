# Cell border protocol: rationale

Why [cell-border-protocol.md](cell-border-protocol.md) is shaped the way it is, what came before
it, and what was left out on purpose.

## Motivation

Terminal applications draw boxes all the time: panes, popups, text fields, buttons, tables, diff
views. Today they use box-drawing characters, which cost a whole column or row per edge. An 80×24
layout with three panes loses a noticeable share of its space to lines one pixel wide. Box
characters also can't sit between two cells, can't share a cell with text, and can't outline
half-block or quadrant shapes.

[Will McGugan's "the CEO just wants to draw boxes"](https://www.willmcgugan.com/blog/tech/post/ceo-just-wants-to-draw-boxes/)
describes the same frustration from the Textual side. Common [ratatui](https://ratatui.rs) apps
(multi-pane tools such as [gitui](https://github.com/gitui-org/gitui) and
[bottom](https://github.com/ClementTsang/bottom), diff viewers, roguelikes, forms and popups) would
gain room and clarity.

What sets this protocol apart from earlier work is the combination of:

- every segment independently coloured and sized;
- half edges and centre arms, which compose with Unicode half blocks and quadrants;
- inside and centred placement, so both adjacent outlines and shared dividers work;
- double, dashed and dotted lines and rounded corners and forks, which compose with each other;
- a pen, so applications treat borders as part of a cell's style and existing screen-diffing
  renderers need little change.

## Prior art

### DEC ruled lines (DECterm)

[DECterm](https://ftp.zx.net.nz/rom/V4.0D_D1/DOCS/HTML/AQ0R4CTE/DOCU_006.HTM) defines
`DECDRLBR` (`CSI P1;Px;Plx;Py;Ply ,r`, draw lines on the bottom, right, top and left boundaries of
a rectangle), `DECERLBRP` (erase by pattern, `,s`) and `DECERLBRA` (erase all, or within a
rectangle, `,t`). Support is announced as extension 43 in the DA1 reply.
[C-Kermit for Windows](https://github.com/davidrg/ckwin/pull/500) has implemented them.

Lifetime, from the manual's interaction table, confirmed by the ckwin implementation:

- Ruled lines scroll with text, and IL and DL move them with their lines.
- ED, EL, ECH and FF (Ctrl+L) do **not** erase them; only the characters go. A clear screen
  leaves the lines behind.
- ICH, DCH and insert mode do not move them sideways.
- RIS erases them; DECSTR does not.
- They are always one pixel wide and the normal screen colour; there is no colour or width.
- Coordinates are absolute, and the draw operation applies its pattern to the rectangle's
  perimeter.

This protocol keeps the scrolling behaviour but deliberately differs on erase. DEC lines are a
layer laid over the text that erase leaves alone, so an application that clears and redraws
leaves stale lines behind and must track them separately. Treating borders like a background
colour (erase replaces them with the current pen) makes a cleared screen actually clear and lets
borders ride along with normal redraw logic.

### SGR attributes

[ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/) defines
SGR 51 (framed), 52 (encircled) and 53 (overlined), and SGR 60–63 as ideogram lines: underline or
right side line, double underline or double right line, overline or left side line, and double
overline or double left line, with 64 for stress marking and 65 cancelling 60–64. The left and
right readings apply to vertical writing.

These are per-character decorations with no colour, width or per-side control, and they are
rarely implemented. [xterm](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) implements
none of them. [mintty](https://mintty.github.io/) uses 51 and 52 for emoji presentation, not
frames. RLogin is the only terminal known to draw 60–65 as lines
([VTE #2486](https://gitlab.gnome.org/GNOME/vte/-/issues/2486), request for SGR 60–65).

### Windows console, curses and 3270

- The [Win32 console](https://learn.microsoft.com/en-us/windows/console/console-screen-buffers)
  has per-cell `COMMON_LVB_GRID_HORIZONTAL` (top edge), `COMMON_LVB_GRID_LVERTICAL` and
  `COMMON_LVB_GRID_RVERTICAL` flags, documented for use with DBCS code pages. This is the
  closest model to this protocol, without a bottom edge, colour, width or halves.
- [PDCurses](https://github.com/wmcbrine/PDCurses) has `A_LEFT`, `A_RIGHT` and `A_UNDERLINE`
  lines whose colour is set by `PDC_set_line_color`: separate from the text colour, but one
  global colour for every line.
- [X/Open Curses](https://pubs.opengroup.org/onlinepubs/7908799/xcurses/curses.h.html) defines
  `WA_TOP`, `WA_LEFT`, `WA_RIGHT`, `WA_HORIZONTAL`, `WA_VERTICAL` and `WA_LOW` highlights, with
  no bottom edge. PDCurses defines `WA_TOP`, `WA_HORIZONTAL` and `WA_VERTICAL` as no-ops.
- The IBM 3270 data stream has a field outlining extended attribute (type X'C2') with bits for
  under, right, over and left lines. It outlines whole input fields rather than cells.

### Downloadable glyphs and box characters

[VT220](https://vt100.net/docs/vt220-rm/chapter4.html) soft fonts (DECDLD, a downloadable
character set of up to 94 glyphs) let applications draw custom line glyphs, but each glyph still occupies
a cell. Unicode box drawing, half blocks and quadrants are the current baseline that applications
must fall back to.

### The Rio prototype

[Rio PR #1947](https://github.com/raphamorim/rio/pull/1947) was the first prototype of this idea,
using APC. Ghostty's version moved to DCS, split outer edges into halves and ordered border layers
consistently across rows.

## Decisions

### Borders are a cell attribute

Discussed in [ghostty-org/ghostty#14324](https://github.com/ghostty-org/ghostty/discussions/14324)
(border protocol discussion). The alternatives were a screen-level layer (like DEC ruled lines) or
region objects. A cell attribute answers the hard lifetime questions by reusing rules terminals
already have: borders scroll, insert, delete, reflow and switch screens exactly as cells do.
Regions are wanted for other reasons (accessibility, wrapping, scrollable areas) but bring
anchoring and lifetime semantics this protocol does not need, so they are separate future work.

### A pen, like SGR

The pen makes printing and erasing apply borders the way they apply the background colour.
Screen-diffing renderers such as ratatui already compare each cell's style with the previous
frame; with a pen, a border is just another style field. Without one, every text write would have
to be followed by a repaint of the borders it destroyed, which the earlier prototype required.

The one rule ("every cell the terminal writes or blanks takes the pen") reuses the terminal's
existing blank-cell path for background colour erase, which keeps implementations consistent: the
operation table in the spec follows from it rather than being a list of special cases.

Rectangle commands stay for applications that don't diff by cell, and for painting borders on
cells without rewriting their text.

### SGR 0 clears the pen

A crashed or careless application can leave the pen set. Shell prompts send SGR 0 constantly, so
tying the pen's reset to SGR 0 stops every later character in the shell from gaining borders.
Other SGR parameters leave the pen alone so that colour changes mid-line don't drop borders.

### Shared edges merge by priority, then width, then position

Two adjacent panes that each draw their own outline should produce one divider, not a double
line. Merging centred strokes on a shared edge gives that, resolved when drawing so that cell
ownership stays simple: scrolling or ICH never has to repair a neighbour.

The winner must not depend on write order. Buffer-diffing renderers such as ratatui send only
changed cells, in screen order, so an application cannot make a highlighted pane's outline "draw
last". An earlier draft used "right and bottom win", which broke exactly that case: a focused pane
lost its right and bottom edges to unfocused neighbours. Last-write-wins was also rejected for the
same reason, and because it would need per-edge history.

Instead, an explicit `priority` decides, then width, as in CSS's collapsed table borders, where
the wider border wins. Position is only the final tie-break. `priority` is an extension field, so a
terminal that predates it still merges by width and position.

### Two placements

Inside placement lines up with block and quadrant glyph edges and lets neighbours keep distinct
outlines. Centred placement makes a single line on the boundary, which is what pane dividers want
and what merging is for. Both are cheap to implement, and removing one later is easier than adding
it after applications depend on the protocol.

### Width relative to cell width

Using the cell width for both orientations keeps lines visually equal on tall cells. Units of
1/256 of a cell, with a minimum of one device pixel, scale with font size and display density.
The cap of 64 (one quarter of a cell) keeps borders lines rather than fills, while leaving room
for a double line to read as two lines with a visible gap.

### Colours by value, palette or default foreground

`RRGGBB` gives exact colours, while `pN` and `fg` follow the user's theme and live palette changes,
which applications that respect themes expect.

### DCS framing, not APC or OSC

APC was rejected because it is not safe: Kermit 95 has run APC payloads as Kermit commands since
about 1994. DCS is the established home for structured terminal commands, is ignored by
conforming parsers that don't understand it, and lets the intermediate and final bytes plus a text
namespace make collisions unlikely. `DCS 1 + b` avoids xterm's `DCS + p` and `DCS + q`. OSC
would also work, but OSC numbers are a crowded, informally allocated space.

The namespace is `cell-border` rather than a terminal name so that other terminals can implement
the same protocol without it looking vendor-specific. The leading parameter is a protocol version,
so incompatible future changes can be rejected cleanly.

### Capability query plus DA1

A dedicated query gives the version and feature list. Following it with DA1 turns "no reply" into
a prompt negative answer, since every terminal and multiplexer answers DA1 in order. That lets an
application decide quickly whether to spend columns on box characters, and never spend them twice
when borders are available.

### Multiplexers

tmux and zellij redraw panes from their own cell grids. Borders forwarded through passthrough
would be wiped or misplaced on the next redraw, so passthrough is ruled out. Because multiplexers
drop unknown DCS and answer DA1 themselves, applications in them get a clean negative. Native
multiplexer support is a straightforward extension: store borders per cell and re-emit them with
the pen.

### Extension fields degrade instead of failing

Positional fields are frozen once terminals ship: if a later version added a positional field,
every version 1 terminal would reject the whole command and draw nothing. Optional `key=value`
fields that terminals must ignore when unknown let a request for a double line draw a single line
on an older terminal instead. That is the right fallback, because borders take no layout space, so
a plainer line never breaks a layout. Applications that need the exact look still check the feature
list. Additions that cannot degrade sensibly, such as a finer subdivision mask, should instead be
new operations or larger mask values that older terminals reject.

### Line styles are per segment

Double, dashed and dotted lines are modelled now, not deferred, so the storage, merge rule and join
rules are designed with them rather than retrofitted. They are a property of each segment, which
makes mixed junctions such as `╟` and `╞` plain data. Joins follow Unicode box drawing, the
reference every application already falls back to, so a bordered layout and its box-character
fallback look alike. `WIDTH` is the total thickness so that double lines have a defined budget.

Dash patterns repeat per half-segment rather than along a run. Patterns along a run would need
the terminal to know where runs begin, which cell attributes cannot express, and they would shift
whenever part of a run is redrawn.

### Rounded joints are per-cell quadrant flags

Rounding is a property of where segments meet, not of the segments, so it lives in joint flags.
Each flag names a quadrant inside its own cell: the four quadrants around the cell's centre and the
quadrant of each corner point that falls inside the cell. An earlier idea gave each corner point
one owning cell (the lower-right one, matching the merge rule), but then a panel's bottom-right
corner would be owned by a cell outside the panel, or by no cell at the screen edge. Per-cell
quadrants keep every widget's corners inside its own area, which is what ratatui-style renderers
need.

The two drawing rules (arcs for rounded quadrants; an arm stops short only when it has no
straight continuation and is rounded on a side) cover rounded corners, forks, split stems and
filleted crossings with one mechanism. Arcs take the horizontal arm's stroke so that a rounded
heavy, double or dashed corner falls out of the line styles with no extra fields. Unicode has only
light arcs (`╭╮╯╰`), so this goes beyond what box characters can draw.

Rounding is a separate `round` feature so that a terminal can ship line styles first. The joint
operations are new operations, so version 1 terminals without the feature ignore them and draw
square corners.

jcollie's concern: a rounded corner over a cell background shows the background's square corner.
That is no worse than `╭` today, so it does not block arcs, but a panel with a background colour
then looks wrong exactly where rounding is meant to help.

### Rounded corners fill outside, not inside

The `outside` key names the colour of what lies beyond the panel, and the terminal paints it into
the corner the arc cuts off. The alternative, extending the panel's background inward from
neighbouring cells or outward around the arc, would make one cell's drawing depend on its
neighbours' backgrounds and on where a region begins, which this protocol avoids everywhere else.
An outside colour keeps the fix cell-local: the application already knows what it drew around the
panel, and `default` covers the common case of a panel on the terminal's own background without
the application knowing that colour. One colour per cell is enough because a cell's rounded corners
all face out of the same panel; a corner between two differently coloured surroundings is rare
enough to leave to full background extension, which stays deferred. The fill draws below both
border layers so that strokes, including neighbours' centred strokes, stay on top.

### Radius is a cell property with a modest default

A radius as wide as the cell made rounded panels look rounder than the window around them. The
default is half the cell width, which at common font sizes lands near typical window corner radii
(roughly 8 to 12 pixels), so a panel's corners read like the window's. Applications that want
another look set `radius`, in the same 1/256-of-cell-width units as stroke widths so that it scales
with the font. It is stored per cell like `outside`, because one cell's joints belong to one panel
corner; the terminal still clamps it to what the arms allow, so no value can draw outside the cell.

## Deferred

- **Background extension around bordered regions.** Letting a region's background reach the
  border line, rather than stopping at cell edges, would fix half-cell padding and the corner
  colour under rounded joints, but extends a cell's rendering into its neighbours.
- **Regions and objects** for accessibility, wrapping and scrollable areas.
- **Sextant and octant subdivision**, to match newer Unicode block characters.
- **Transparency and arbitrary layering.** Layers 0 and 1 cover drawing under or over wide
  characters, which was the case raised in the discussion.
- **Querying the pen**, for example through DECRQSS.
