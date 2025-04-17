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

## Bioinformatics Examples

Examples of use by the NPG team at Sanger. 

Here we use `singularity` to run the container containing P4, its templates, and (many of) the bioinformatics tools we use (but not reference data).

The reference data

### Realignment

From an existing CRAM file, purge existing alignment info and add new GRCh38 based bwa mem alignments and duplicate marking.

The `ref_repository` environment variable sets the expected GRCh38 genome reference data to be below `${ref_repository}/references/Homo_sapiens/GRCh38_full_analysis_set_plus_decoy_hla/all/` as follows:

```text
bwa-mem2/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa
bwa-mem2/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.0123
bwa-mem2/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.alt
bwa-mem2/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.amb
bwa-mem2/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.ann
bwa-mem2/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.bwt.2bit.64
bwa-mem2/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.fai
bwa-mem2/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.pac
fasta/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa
fasta/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.alt
fasta/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.fai
picard/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.dict
```


```bash
export container_url=${container_url:-"docker://ghcr.io/wtsi-npg/p4:latest"}
export base=${base:-"$PWD"}
export inputs=${inputs:-"${base}/inputs/"}
export workarea=${workarea:-"${base}/workarea"}
export outputs=${outputs:-"${base}/outputs"}

export r='some_run'    # relative location/directory used in both input and output file hierarchies
export rpt='some_data' # name of file prefix for both input and output files

export ref_repository=${ref_repository:-"/lustre/scratch125/core/sciops_repository"} # REPLACE with location of your reference files

export reference_genome_fasta="references/Homo_sapiens/GRCh38_full_analysis_set_plus_decoy_hla/all/fasta/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa"
export reference_dict="references/Homo_sapiens/GRCh38_full_analysis_set_plus_decoy_hla/all/picard/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa.dict"
export alignment_reference_genome="references/Homo_sapiens/GRCh38_full_analysis_set_plus_decoy_hla/all/bwa-mem2/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa"

export alignment_reference_genome="references/Homo_sapiens/GRCh38_full_analysis_set_plus_decoy_hla/all/bwa0_6/Homo_sapiens.GRCh38_full_analysis_set_plus_decoy_hla.fa"

singularity exec --bind "${ref_repository}:/mnt/ref_repository,${inputs}:/mnt/inputs,${outputs}:/mnt/outputs,${workarea}:/mnt/workarea" "${container_url}" \
bash <<EOF
export REF_PATH=/mnt/ref_repository/cram_cache/%2s/%2s/%s:URL=http://refcache.dnapipelines.sanger.ac.uk::8000/%s && \
cd /mnt/workarea/"${r}" && \
vtfp.pl -template_path /usr/local/data/vtlib \
 -param_vals /usr/local/data/static_params/stage2_reanalysis/base_params_samtools_cram.json,/usr/local/data/static_params/stage2_reanalysis/align_bwa_mem2.json \
 -export_param_vals /mnt/outputs/"${r}"/"${rpt}"_p4s2_pv_out.json \
 -keys cfgdatadir,aligner_numthreads,br_numthreads_val,b2c_mt_val -vals /usr/local/data/vtlib/,6,6,6 \
 -keys bwa_executable -vals bwa0_6 \
 -keys reference_genome_fasta -vals /mnt/ref_repository/"${reference_genome_fasta}" \
 -keys reference_dict -vals /mnt/ref_repository/"${reference_dict}" \
 -keys alignment_reference_genome -vals /mnt/ref_repository/"${alignment_reference_genome}" \
 -keys incrams -vals /mnt/inputs/"${r}"/"${rpt}".cram \
 -keys outdatadir -vals /mnt/outputs/"${r}"/ \
 -keys seqchksum_orig_file -vals /mnt/outputs/"${r}"/"${rpt}".orig.seqchksum \
 -keys rpt -vals "${rpt}" \
 -keys pp_read2tags,realignment_switch -vals off,1 \
 alignment_wtsi_stage2_template.json > run_"${rpt}".json 2> vtfp_err_log_"${rpt}".txt && \
viv.pl -s -x -v 3 -o viv_"${rpt}".log run_"${rpt}".json
EOF
```
