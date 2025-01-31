# P<sup>4</sup> | Process and Pipe Pipeline Panacea

p4 is a tool to help streaming of data between processes (creating a data pipeline).

## Rationale

The UNIX pipe `|` is typically used for this purpose of streaming data between processes.

When there is a need for part of the same data stream to be processed in more than one way the `tee` tool may be used together with shell process substitution e.g.

```
tool1 | tee >(tool2a > 2a.out) | tool2b > 2b.out
```

Should another tool need to combine those two outputs (in a streaming manner) then UNIX fifos can be used.

Scripts to perform such combinations of streaming data flow can rapidly become somewhat messy and tricky to maintain.

Better, perhaps, to declare this streaming data flow as a graph and create the processes (nodes) and appropriate pipes and fifos between them (edges) in a standard manner from that declaration: this is p4. 

## Nuance

- (unless using async IO) pipes will only allow an `open` to complete when the other end of the pipe also has an `open` called on it. Deadlocks can be created when one tool is waiting on another which is effectively waiting on the original.
- pipes have a limited size. Where there are bubble-like structures in a dataflow, one side of the bubble may try to grab data in very different chunk sizes to the other side. This can then lead to a deadlock when joining the data flows together.
- `SIGPIPE` on one output will terminate `tee` - if only the beginning of the data stream is required on one output this needs to be dealt with to allow the stream to continue on the other outputs.

To help resolve the later two issues we can use the [`teepot`](https://github.com/wtsi-npg/teepot) tool in the graph of processes in place of `tee`.


## Component scripts

There are two key scripts in p4:

- [`viv.pl`](./README) creates the processes, and the fifos and pipes to stream data between them for a particular graph (provided in a JSON file).
- [`vtfp.pl`](README.vtfp) allows for reuse of standard pipelines by taking parameters and template JSON files to create the graph JSON file fed to `viv.pl`


## Motivation and Bioinformatics

In the early 2010s, NPG, a core informatics team at Wellcome Sanger Institute, found ourselves having to process a rapidly increasing amount of short read sequencing data on "fat" NFS servers rather than high performance filesystems, like Lustre, to keep hardware costs at an acceptable level. This drove us to avoid disk IO (to avoid IO wait and poor CPU usage) where possible by streaming data between tools.

We still advocate this as it avoids:
- the need for performant staging disk for many intermediate files
- the added latency of writing and reading data from such staging disk
- the CPU spent on compressing and decompressing data as it is shuttled on and off the staging disk.

The downsides of streaming data are that
- restarting a failed job cannot be from intermediate files which do not exist (we find this only really impacts when developing pipelines rather than once in production),
- the size of the data pipeline in terms of CPU and RAM required is limited by the size of individual machines available, and that 
- contemporary (2024) bio-informatics frameworks only support such streaming in a limited way and often advise against it (as not fitting well with reusability of components in their paradigm. However, p4 or something like it could fit happily as a functionally and computationally big step in such a pipeline).

