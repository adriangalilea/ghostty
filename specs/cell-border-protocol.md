# Cell border protocol

Status: draft, version 1. Not registered with any standards body. Implemented experimentally in
Ghostty. See [cell-border-rationale.md](cell-border-rationale.md) for why each choice was made and
for prior art.

Cell borders are thin, independently styled lines drawn on the edges and centrelines of terminal
cells. They do not consume character positions: a bordered panel uses the same cells as an
unbordered one. Borders are a cell attribute, like a background colour, so they move, scroll,
erase and reflow with the cells that carry them.

## Terms

- **Segment**: one of twelve primitive line pieces of a cell (see [Segments](#segments)).
- **Stroke**: the style of one segment: width, colour, placement, layer and line style. A
  segment either has a stroke or is absent.
- **Joint**: a point where segments meet: a cell's centre or one of its corners. Each cell has
  eight joint flags that choose square or rounded corners (see [Joints](#joints)).
- **Border set**: a cell's twelve segments, eight joint flags, outside colour and radius.
- **Pen**: a border set held in the cursor state. Cells the terminal writes or blanks receive the
  pen, the same way they receive the current background colour.
- **Rectangle commands**: commands that change the border sets of existing cells directly
  without using or changing the pen.

## Framing

All commands are DCS strings:

```text
DCS 1 + b cell-border ; OP [ ; FIELD ]* ST
```

- `DCS` is `ESC P` and `ST` is `ESC \`. Terminals should also accept the 8-bit forms where they
  accept them for other DCS strings. Applications should send the 7-bit forms.
- The DCS has exactly one numeric parameter, `1` (the protocol version), the intermediate `+` and
  the final `b`.
- The payload starts with the literal namespace `cell-border`. A terminal must ignore the
  sequence if the parameter, intermediate, final or namespace differ.
- Fields are separated by `;`. There is no whitespace. Spaces in examples are for reading only.
- A payload longer than 256 bytes is ignored.
- A malformed command (unknown operation, missing positional fields, out-of-range value) is
  ignored entirely. A terminal never applies part of a malformed command.
- Commands that take a stroke, and the joint operations, accept optional `key=value` fields after
  their last positional field. See [Extension fields](#extension-fields).
- No command moves the cursor or changes SGR attributes, except where stated below.

## Operations

| `OP` | Fields | Reply | Effect |
| --- | --- | --- | --- |
| `q` | none | yes | Capability query |
| `pen` | `MASK;STROKE` | no | Set the selected pen segments to `STROKE` |
| `pen-clear` | `MASK` | no | Remove the selected pen segments |
| `set` | `MASK;STROKE;ROWS;COLS` | no | Set the selected segments on every cell in a rectangle |
| `clear` | `MASK;ROWS;COLS` | no | Remove the selected segments from every cell in a rectangle |
| `pen-round` | `JOINTS` | no | Round the selected pen joints |
| `pen-square` | `JOINTS` | no | Make the selected pen joints square |
| `round` | `JOINTS;ROWS;COLS` | no | Round the selected joints of every cell in a rectangle |
| `square` | `JOINTS;ROWS;COLS` | no | Make the selected joints of every cell in a rectangle square |

`STROKE` is the four fields `WIDTH;COLOR;PLACEMENT;LAYER` (see [Strokes](#strokes)). Written
out:

```text
DCS 1 + b cell-border;pen;MASK;WIDTH;COLOR;PLACEMENT;LAYER[;KEY=VALUE]* ST
DCS 1 + b cell-border;pen-clear;MASK ST
DCS 1 + b cell-border;set;MASK;WIDTH;COLOR;PLACEMENT;LAYER;ROWS;COLS[;KEY=VALUE]* ST
DCS 1 + b cell-border;clear;MASK;ROWS;COLS ST
DCS 1 + b cell-border;pen-round;JOINTS[;KEY=VALUE]* ST
DCS 1 + b cell-border;pen-square;JOINTS[;KEY=VALUE]* ST
DCS 1 + b cell-border;round;JOINTS;ROWS;COLS[;KEY=VALUE]* ST
DCS 1 + b cell-border;square;JOINTS;ROWS;COLS[;KEY=VALUE]* ST
DCS 1 + b cell-border;q ST
```

### Fields

| Field | Syntax | Meaning |
| --- | --- | --- |
| `MASK` | decimal `1..4095` | Bitwise OR of [segment](#segments) bits |
| `JOINTS` | decimal `1..255` | Bitwise OR of [joint](#joints) bits |
| `WIDTH` | decimal `1..64` | Total thickness in 1/256 of the cell width, at least one device pixel |
| `COLOR` | `RRGGBB`, `pN`, or `fg` | See [Colours](#colours) |
| `PLACEMENT` | `0` or `1` | `0`: inside the cell. `1`: centred on the cell edge |
| `LAYER` | `0` or `1` | `0`: below text. `1`: above text |
| `ROWS`, `COLS` | decimal `1..65535` | Rectangle size from the cursor |

Decimal fields have no sign and no leading `+`. Leading zeros are allowed.

### Extension fields

After the positional fields, a stroke command or joint operation may carry any number of
`KEY=VALUE` fields. `KEY` is one or more of `a-z` and `-`; `VALUE` is one or more of `a-z`, `0-9`
and `-`. A field that doesn't match this syntax makes the command malformed, so hex colours in
values are lowercase.

A terminal must ignore keys it does not know, and known keys with values it does not know,
without rejecting the command. If a key appears more than once, the last one wins. This lets
applications request newer styles and get the version 1 rendering on older terminals. Applications
that need exact rendering check the [feature list](#capability-query).

| Key | Values | Default | Feature |
| --- | --- | --- | --- |
| `style` | `solid`, `double`, `dashed`, `dotted` | `solid` | `style` |
| `priority` | decimal `0..15` | `0` | `priority` |
| `outside` (joint operations) | lowercase `rrggbb`, `pN`, or `default` | none | `outside` |
| `radius` (joint operations) | decimal `1..256`, in 1/256 of cell width | terminal default | `radius` |

## Capability query

```text
-> DCS 1 + b cell-border;q ST
<- DCS 1 + b cell-border;ok;VERSION;FEATURES ST
```

`VERSION` is the highest protocol version supported (`1`). `FEATURES` is a comma-separated list.
Version 1 terminals report at least `pen,rect,half,center,palette` and may also report `style`,
`round`, `priority`, `outside` and `radius`. Applications must ignore features they do not
recognise. A later version may add features without changing `VERSION`.

| Feature | Meaning |
| --- | --- |
| `pen` | `pen` and `pen-clear` |
| `rect` | `set` and `clear` |
| `half` | Half outer edges (bits 0–7 individually) |
| `center` | Centreline arms (bits 8–11) |
| `palette` | `pN` and `fg` colours |
| `style` | The `style` key: double, dashed and dotted lines |
| `round` | The joint operations: rounded corners and forks |
| `priority` | The `priority` key for shared edges |
| `outside` | The `outside` key: filling the corner a rounded joint cuts off |
| `radius` | The `radius` key: the arc radius of rounded joints |

### Detecting support without a timeout

Send the query immediately followed by Primary Device Attributes (`CSI c`). Terminals answer
requests in order, so:

- a border reply before the DA1 reply means support;
- a DA1 reply with no border reply before it means no support.

Terminals and multiplexers that do not implement this protocol discard the unknown DCS and still
answer DA1, so this works through them too. Applications that do not see support must fall back
to ordinary box-drawing characters and reserve the columns and rows those characters need. A
timeout is only needed for terminals that do not answer DA1.

An application must not assume support from `TERM`, `TERM_PROGRAM` or similar variables.

## Segments

Each cell has twelve segments: two halves of each outer edge and four centre arms.

```text
                 TOP_LEFT       TOP_RIGHT
              +--------------+--------------+
     LEFT_TOP |              |              | RIGHT_TOP
              |            V_TOP            |
              +--- H_LEFT ---+--- H_RIGHT --+
              |          V_BOTTOM           |
  LEFT_BOTTOM |              |              | RIGHT_BOTTOM
              +--------------+--------------+
                BOTTOM_LEFT    BOTTOM_RIGHT
```

| Segment | Bit | Mask | | Name | Mask |
| --- | --- | --- | --- | --- | --- |
| `TOP_LEFT` | 0 | 1 | | `TOP` | 3 |
| `TOP_RIGHT` | 1 | 2 | | `RIGHT` | 12 |
| `RIGHT_TOP` | 2 | 4 | | `BOTTOM` | 48 |
| `RIGHT_BOTTOM` | 3 | 8 | | `LEFT` | 192 |
| `BOTTOM_LEFT` | 4 | 16 | | `OUTLINE` | 255 |
| `BOTTOM_RIGHT` | 5 | 32 | | `HORIZONTAL` | 768 |
| `LEFT_TOP` | 6 | 64 | | `VERTICAL` | 3072 |
| `LEFT_BOTTOM` | 7 | 128 | | `ALL` | 4095 |
| `H_LEFT` | 8 | 256 | | | |
| `H_RIGHT` | 9 | 512 | | | |
| `V_TOP` | 10 | 1024 | | | |
| `V_BOTTOM` | 11 | 2048 | | | |

Full edges are two halves, not a separate slot: setting `TOP`, then `TOP_LEFT` with another
stroke, changes only the left half. Half edges and centre arms together outline any Unicode
quadrant or half block. For example, `▘` is outlined by `TOP_LEFT|LEFT_TOP|H_LEFT|V_TOP`
(mask 1345).

## Strokes

### Colours

| `COLOR` | Meaning |
| --- | --- |
| `RRGGBB` | Exactly six hex digits, either case. Opaque RGB. |
| `pN` | Palette index `N`, decimal `0..255`. |
| `fg` | The terminal's default foreground colour. |

Palette and `fg` colours are resolved when drawing, so they follow theme changes and OSC 4/10
updates, like text colours. Border colours never depend on the cell's SGR colours.

### Width and placement

`WIDTH` is measured against the cell width for both horizontal and vertical segments, so equal
widths look equally thick on non-square cells. A width always rounds to at least one device pixel.

- **Inside** (`0`): the stroke lies entirely inside its cell, flush with the edge. Inside strokes
  align with the edges of block and quadrant glyphs.
- **Centred** (`1`): the stroke is centred on the cell edge and extends into the neighbouring cell
  by half its width. Strokes past the edge of the viewport are clipped.

Centre arms are always centred on the cell's centrelines; `PLACEMENT` has no effect on them.
Segments that meet overlap at their joint, so corners and junctions have no gaps. Corners are
square unless the joint is [rounded](#joints).

### Line styles

The `style` key chooses how a stroke is drawn within its `WIDTH`:

- **`solid`**: one line, the full width.
- **`double`**: two parallel lines with a gap between them, each line and the gap about a third
  of the width. Each line and the gap are at least one device pixel, so a double stroke is at
  least three pixels.
- **`dashed`**: each half-segment is drawn as one dash covering its middle half.
- **`dotted`**: each half-segment is drawn as one square dot, as wide as the stroke, at its
  middle.

Dash and dot patterns repeat per half-segment, so they line up across cells and on shared
edges without any phase state.

Where segments meet, lines join the way the matching Unicode box-drawing characters do
(`┼ ╬ ╪ ╫ ╟ ╞` and so on): double lines meeting double lines connect outer to outer and inner
to inner and keep their interior open, and a single line meeting a double line from the side stops
at the double line's nearer side. Combinations with no Unicode character (such as heavy double,
or mixed widths) follow the same rules.

### Layers

`LAYER 0` draws above cell backgrounds and below text. `LAYER 1` draws above text. Borders always
draw above backgrounds. Within a layer, order is rows top to bottom, cells left to right, segments
in bit order; later strokes cover earlier ones. The text cursor draws above borders, except that a
block cursor draws below above-text borders. Images keep their existing placement relative to text.

## Shared edges

The right edge of a cell and the left edge of its right-hand neighbour are the same line, as are
a bottom edge and the top edge of the cell below. When both cells have a **centred** stroke on
the matching half-segment, only one is drawn. The winner is chosen by, in order:

1. the higher `priority`;
2. the greater `WIDTH`;
3. the right-hand (or lower) cell.

The result never depends on the order in which cells were written, so applications that render
from a cell buffer can highlight one panel (for example with `priority=1`) without controlling the
order of their output. Matching pairs:

| Left or upper cell | Right or lower cell |
| --- | --- |
| `RIGHT_TOP` | `LEFT_TOP` |
| `RIGHT_BOTTOM` | `LEFT_BOTTOM` |
| `BOTTOM_LEFT` | `TOP_LEFT` |
| `BOTTOM_RIGHT` | `TOP_RIGHT` |

Line style and colour do not affect the choice; the winning stroke keeps its own style and
colour. Inside strokes never merge: two adjacent cells with inside strokes on a shared edge draw
two lines, and a centred and an inside stroke on the same edge both draw.

Merging happens only when drawing. Each cell keeps its own border set, so moving or erasing one
cell never changes its neighbour.

## Joints

Joints decide whether two meeting segments form a square corner or a rounded one. Each cell has
eight joint flags, one for each quadrant of each joint point that lies inside the cell: four at
the cell's centre and one at each of its corners.

| Joint | Bit | Mask | Arms it joins |
| --- | --- | --- | --- |
| `CORNER_TOP_LEFT` | 0 | 1 | `TOP_LEFT` and `LEFT_TOP` |
| `CORNER_TOP_RIGHT` | 1 | 2 | `TOP_RIGHT` and `RIGHT_TOP` |
| `CORNER_BOTTOM_RIGHT` | 2 | 4 | `BOTTOM_RIGHT` and `RIGHT_BOTTOM` |
| `CORNER_BOTTOM_LEFT` | 3 | 8 | `BOTTOM_LEFT` and `LEFT_BOTTOM` |
| `CENTER_TOP_RIGHT` | 4 | 16 | `V_TOP` and `H_RIGHT` |
| `CENTER_BOTTOM_RIGHT` | 5 | 32 | `H_RIGHT` and `V_BOTTOM` |
| `CENTER_BOTTOM_LEFT` | 6 | 64 | `V_BOTTOM` and `H_LEFT` |
| `CENTER_TOP_LEFT` | 7 | 128 | `H_LEFT` and `V_TOP` |

Named groups: `CORNERS` (15) and `CENTER` (240). All flags start square.

Because each flag names the quadrant inside its own cell, a cell can round its own corners without
writing to its neighbours, so a widget drawing inside its own area can round all four of its
corners.

### Drawing rules

A rounded quadrant takes effect only when both of its arms are present after
[shared-edge](#shared-edges) merging, and the cell's own strokes won the merge. Otherwise the flag
has no effect.

At each joint:

1. Every rounded quadrant whose arms are present draws an arc joining those two arms, tangent to
   both. The arc uses the stroke of the horizontal arm: its width, colour, style and layer.
2. An arm stops short of the joint, where its arcs begin, if the arm opposite it is absent and at
   least one of the quadrants beside it is rounded. Otherwise it runs to the joint as usual.

This gives:

| Arms present | Rounded quadrants | Result |
| --- | --- | --- |
| Two, perpendicular | Theirs | Rounded corner (`╭`) |
| Two, perpendicular | None | Square corner (`┌`) |
| Three (a T) | One beside the stem | Fork: the straight line continues and the stem curves into it on one side |
| Three (a T) | Both beside the stem | The stem splits into two arcs, one each way |
| Four | Any | Straight lines cross; each rounded quadrant adds a fillet |

The `radius` extension field of the joint operations sets the arc radius in 1/256 of the cell
width, the same unit as `WIDTH`. Without it the terminal chooses; the recommended default is `128`,
half the cell width. Each cell stores one radius, shared by its rounded joints and set, kept and
cleared like the [outside colour](#outside-fill). `0` and out-of-range values are ignored.

The radius is at most the smaller of the cell's width and height. A radius longer than a
half-segment continues into the next collinear half-segment of the same cell. If that half-segment
is absent or has a different stroke, the radius shrinks to fit the arms that are there. For
example, `DCS 1 + b cell-border;round;255;5;20;radius=64 ST` rounds every joint in a 5×20
rectangle with a quarter-width radius.

Arcs are anti-aliased; straight lines stay pixel-aligned. Rounded double lines draw two concentric
arcs, and dashed and dotted arcs continue their pattern along the arc.

Corner joints follow `PLACEMENT`: for inside strokes the corner is inside the cell, and for centred
strokes it is on the cell's corner point.

### Outside fill

By default arcs never change cell backgrounds: a rounded corner over a cell background leaves the
background's square corner visible, as box-drawing characters do today. The `outside` extension
field of the joint operations names a colour for the area the arc cuts off:

| Value | Colour |
| --- | --- |
| `rrggbb` | Lowercase hexadecimal RGB |
| `pN` | Palette index `0..255` |
| `default` | The terminal's default background, resolved at draw time like palette colours |

Each cell stores one outside colour, shared by all of its rounded joints. `pen-round` and
`pen-square` with `outside` set the pen's colour; `round` and `square` with `outside` set it on
every cell in the rectangle. A joint operation without `outside` leaves the colour unchanged, and
squaring every joint leaves it stored but unused. SGR 0 clears it with the rest of the pen.

For every rounded quadrant that draws an arc, the terminal fills the region between the arc's outer
edge and the corner of the square the arc spans, within the cell's own pixels, with the outside
colour. The fill is anti-aliased along the arc so that it meets the arc without a seam. It draws
above cell backgrounds and below text and both border layers. For centred corners only the part
inside the cell is filled; the neighbouring cells keep their own backgrounds.

## The pen

The pen is part of the cursor's rendition state, alongside SGR attributes. It starts empty.

The pen is a border set: segments with their strokes, joint flags, outside colour and radius.

Every cell the terminal writes or blanks takes a copy of the pen as its border set, replacing
what was there. With an empty pen, this clears the cell's borders and makes its joints square.

| Operation | Effect on borders |
| --- | --- |
| Printing a character | The cell takes the pen |
| Printing a wide character | Both cells take the pen, except that the right-hand edge segments and right-hand corner joints are omitted from the first cell, and the left-hand ones from the second, so no line appears inside the glyph |
| Overwriting half of a wide character | The other half is blanked and takes the pen |
| ECH, EL, ED (0, 1, 2) | Erased cells take the pen |
| ED 3 (erase scrollback) | Borders in scrollback are removed with the lines |
| ICH, DCH | Shifted cells keep their borders; new blank cells take the pen |
| IL, DL, SU, SD, linefeed at the bottom margin, RI at the top margin | Moved lines keep their borders; new blank lines take the pen |
| DECSED, DECSEL (selective erase) | Erased cells take the pen; protected cells keep their borders |
| Other operations that write or blank cells | The written or blanked cells take the pen |
| Rectangle `set`, `clear`, `round` and `square` | Change only the cells in the rectangle; the pen is unchanged |
| SGR 0 (including `CSI m`) | Clears the pen |
| Other SGR parameters | The pen is unchanged |
| DECSC, DECRC | The pen is saved and restored with the other rendition state; DECRC with nothing saved clears the pen |
| Modes 1048 and 1049 | Save and restore the pen as DECSC and DECRC do |
| DECSTR | Clears the pen; borders on cells are unchanged |
| RIS | Clears the pen and all borders, including in scrollback |
| DECCOLM | Clears the screen and its borders |

The pen never affects cells the terminal does not write or blank: moving the cursor, changing
margins and scrolling the viewport leave existing borders as they are.

## Rectangle commands

`set`, `clear`, `round` and `square` act on the rectangle whose top-left cell is the cursor
position, `ROWS` tall and `COLS` wide, clipped to the screen. Scrolling margins do not clip it. Origin mode affects only
where the cursor already is.

- `set` gives every cell in the rectangle the stroke on the selected segments. It does not draw
  only the perimeter; to outline a panel, set four one-cell-wide strips.
- `clear` removes the selected segments from every cell in the rectangle.
- `round` and `square` change the selected joint flags of every cell in the rectangle.
- Unselected segments and joints are unchanged.
- Rectangles address physical cells, so a rectangle may give the two cells of a wide character
  different borders.

If the terminal runs out of storage, a rectangle may be partly applied. Applications that need a
known state can clear and repaint.

## Cells, screens and reflow

- Borders belong to cells, so the primary and alternate screens have separate borders, and
  scrollback keeps the borders lines had when they scrolled off.
- On resize with reflow, borders move with their cells. A blank cell with borders counts as
  content, so it is not trimmed as trailing whitespace. Reflow does not re-lay-out an application's
  panels; applications redraw on resize as usual.
- Font and size changes recompute pixel geometry only.
- Behaviour on double-width and double-height lines (DECDWL, DECDHL) is not defined by version 1.

## What borders do not affect

- Text selection and copying: borders are never copied as characters.
- SGR inverse, faint, conceal and blink, and selection highlighting: borders keep their own colour.
- Hyperlinks, semantic prompts and other cell metadata.

## Multiplexers

A multiplexer must not forward these commands through passthrough (for example tmux
`allow-passthrough`). It redraws panes from its own cell state, so forwarded borders would be lost
or end up in the wrong place. A multiplexer that does not implement this protocol discards the
commands and answers DA1 itself, so applications inside it fall back correctly.

A multiplexer that implements the protocol stores borders as cell attributes, answers the query
itself if the outer terminal supports the protocol, and redraws them to the outer terminal using
the pen and rectangle commands.

## Guidance for applications

Not normative. These notes come from building a ratatui application on the protocol.

- Store each cell's border set with its colours and attributes, and let the normal screen diff
  decide when to send it. Send `pen` or `pen-clear` only when the next cell's border differs from
  the current pen, and clear only the segments that change.
- SGR 0 clears the whole pen, including joints, outside colour and radius. A renderer that resets
  attributes in the middle of a frame must send the pen again before the next bordered cell. Clear
  the pen at the end of each frame so later output, such as a shell prompt, doesn't pick it up.
- When several widgets draw on one cell, such as a pane outline and a text field's underline,
  combine their segments. A widget that replaces the whole border set removes its neighbour's
  edges.
- Use one placement within a component. Inside and centred strokes never merge, so an inside pane
  outline and a centred underline on the same edge both draw.
- For a centred outline around a panel with its own background, put the strokes on the outer
  edges of the panel's outermost cells (`LEFT` on the left column, and so on), not on the
  centrelines of those cells. Otherwise half a cell of background shows outside the line.
- Keep the stroke the same along a rounded edge. Radii longer than a half-segment need the corner
  cell's next half-segment to have the identical stroke; a different colour, width or style there
  shrinks the arc.
- Give every rounded corner cell an outside colour: `default` for a panel on the terminal
  background, or the parent's colour for a popup or menu over another panel. Corner cells often
  hold content with its own background, such as a tab label, which otherwise shows as a square
  corner.
- To highlight a focused panel, raise its strokes' `priority` so it wins every shared edge
  whatever order the cells were sent in.
- Detect support with the query followed by DA1, and add a short timeout for terminals that answer
  neither. Without support, draw box characters and reserve the rows and columns they need.

## Notes for implementers

Not normative. These notes come from the Ghostty implementation.

- Ghostty interns border sets and stores a 16-bit ID in a spare field of each cell. Printing and
  erasing copy that ID, and the existing blank-cell path used for background colour erase applies
  the pen.
- Merging, junction joins and arcs depend on the four neighbouring cells, so when borders are
  present, redrawing a row also redraws the rows above and below it.
- The outside fill must draw after cell backgrounds but before every stroke, including strokes
  from the row above that overflow into the cell. One list per row, drawn top to bottom, can't
  satisfy both, so Ghostty draws fills in a separate layer.
- Anti-aliased arc edges carry partial alpha. Check whether the pipeline blends premultiplied or
  straight alpha, and divide out alpha before any gamma conversion and multiply it back after.

## Not in version 1

Transparency, more than two layers, sextant or octant subdivision, extending
backgrounds around bordered regions, region or object semantics, and querying the current pen.
New stroke properties are expected to arrive as [extension fields](#extension-fields) and new
cell properties as new operations, both of which version 1 terminals ignore. The rationale explains
why each is deferred.
