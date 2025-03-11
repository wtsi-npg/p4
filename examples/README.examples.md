# P<sup>4</sup> Examples

## Using viv.pl and its JSON pipeline description

### Running the examples

To produce a JSON config file from the supplied ".cfg" example files, you must remove the comment lines, tabs and newlines.

```bash
grep -v "^#" example_01.cfg | tr -d "\n\t" > example_01_cfg.json
```

You can then use the viv script with this JSON file (if you are working from the examples directory):

```bash
../bin/viv.pl -s -x -v 3 -o example_01.log example_01_cfg.json
```

The resulting log file is verbose - you may want to reduce the verbosity level (the value supplied to the -v flag).

### `EXEC` and `OUTFILE` type nodes

[example_01.cfg](example_01.cfg) has one edge streaming data from (the `stdout` of) a single `EXEC` node to (the `stdin` of) an `OUTFILE` node.

[example_02.cfg](example_02.cfg) adds an intermediary `EXEC` node in the streaming data flow (again using `stdin` and `stdout`). There are two edges.

These could be achieved more simply using UNIX pipes.

### `RAFILE` type node

[example_03.cfg](example_03.cfg) introduces a single `RAFILE` node to the (still linear, one long line) flow. Any node which relies on the `RAFILE` for its input will not be exec'd until the node writing to the `RAFILE` has completed.

`RAFILE` nodes can be used where a node requires input which cannot be streamed into it e.g. it reads a few bytes to determine file type, then seeks to the beginning of the file to start reading it again.

#### `RAFILE` subtype `DUMMY`

[example_04.cfg](example_04.cfg) introduces the `subtype` of `DUMMY` option to an `RAFILE`. Here the source node generating the file is in control of creating the file.
