# Human Read Removal

Here we describe three methods of Human (Illumina) sequencing read removal used by core
informatics team NPG at the Wellcome Sanger Institute (WSI). This is *not* an exhaustive
description of human read removal methods used at WSI. We recommend *not* using the "legacy"
method.

## npg2025 - Bowtie2-VSL-h38

Bowtie2 is used with its very-sensitive local mode and in unpaired read mode, with the GRCh38
human reference genome. A hit to either of the reads in paired data results in both reads being
categorised as human.

This method was evaluated as a suitable combination of sufficient human read removal and minimal
impact on the bioinformatic analysis of the residue (catagorised non-human) data.
See https://www.biorxiv.org/content/10.1101/2025.03.21.644587v1.full

Whilst we originally found this method within human read removal functionality of the
Kneaddata pipeline, we now implement it within a P4 pipeline running bowtie as described above
followed by a (piped) script to restore read pair information to the SAM/BAM data flow.

## Heron & CoG-UK

Specific to Sanger's part in the CoG-UK consortium. It replicated functionality performed at
the central CLIMB facilty. It relies on prior processing by the ncov2019-artic-nf pipeline
leaving only reads which aligned to the reference viral genome. These were then filtered
further with a human alignment and a Kraken classification.

## npg legacy

We recommend this method is _not_ used. We describe it as a record of how some data was
processed historically.

`bwa aln` is used with a GRCh37 reference (excluding EBV). A hit to either of the reads in
paired data results in both reads being categorised as human.

The use of bwa aln will perform poorly if the sequence extends into adapter. Adapter
detection and removal was done before bwa aln using Biobambam tools for all Illumina
sequencing platforms, except NovaSeq6000 (where, by default, no adapter removal was
performed).
