#!/usr/bin/env bash

set -eo pipefail

#########################
# Singularity environment
#########################
if [ -z "${SINGULARITY_CACHEDIR}" ]
then
  printf "Environment variable SINGULARITY_CACHEDIR must be set to specify cache for Singularity for reanalysis\n" >&2
  exit 1
fi
unset https_proxy
unset http_proxy
unset ftp_proxy
export PATH=/software/singularity/3.11.4/bin:${PATH} # adapt as necessary

required_parameters_missing=0
#######################################################################################################
# pairs of "real world"/Singularity input, output, work area and references repository are
#  mapped using the -bind flag; these variables are just for avoiding lengthy repetition
#  in the Singularity commands (see below)
# This directory structure has "inputs", "outputs" and "workarea" under the same directory - but they
#  do not have to be.
#######################################################################################################
if [ -z "${P4C_REANALYSIS_BASE}" ]
then
  printf "Environment variable P4C_REANALYSIS_BASE must be set to specify base location for reanalysis\n" >&2
  ((++required_parameters_missing))
fi
export base=${P4C_REANALYSIS_BASE} # top-level of work/inputs/outputs area

export workarea="${base}/workarea"
export singularity_workarea="/mnt/workarea"

export inputs="${base}/inputs"
export singularity_inputs="/mnt/inputs"

export outputs="${base}/outputs"
export singularity_outputs="/mnt/outputs"

export ref_repository=${P4C_REF_REPOSITORY:-"/lustre/scratch125/core/sciops_repository"}
export singularity_ref_repository="/mnt/ref_repository"

#######################################################
# sample name (select appropriate values for your data)
#######################################################
if [ -z "${P4C_REANALYSIS_OUTPUT_NAME}" ]
then
  printf 'Environment variable P4C_REANALYSIS_OUTPUT_NAME must be set to specify base name for output files (maybe to RPT value like "123456_7#8")\n' >&2
  ((++required_parameters_missing))
fi
export sample_name=${P4C_REANALYSIS_OUTPUT_NAME} # base name for output files

if [ -z "${P4C_REANALYSIS_INPUT_NAME}" ]
then
  printf "Environment variable P4C_REANALYSIS_INPUT_NAME must be set to specify full path to input files (possibly in irods:) for reanalysis\n" >&2
  ((++required_parameters_missing))
fi
export input_name=${P4C_REANALYSIS_INPUT_NAME} # base name for input files (will be copied to work area)

export aligner=${P4C_TGT_ALIGNER:-"bwa_mem2"}
if [ -z "${P4C_REANALYSIS_REF_ORGANISM}" ] || [ -z "${P4C_REANALYSIS_REF_STRAIN}" ]
then
  printf "Environment variables P4C_REANALYSIS_REF_ORGANISM and P4C_REANALYSIS_REF_STRAIN must both be set to specify reference genome for reanalysis\n" >&2
  ((required_parameters_missing+=2))
fi
export ref_organism=${P4C_REANALYSIS_REF_ORGANISM}
export ref_strain=${P4C_REANALYSIS_REF_STRAIN}
export ref_fnbase=$(ls -t "${ref_repository}"/references/"${ref_organism}"/"${ref_strain}"/all/fasta/*.{fa,fasta} 2> /dev/null | head -1 | xargs -n 1 basename 2>/dev/null)
export submit_jobs_to_lsf=${P4C_LSF_SUBMIT_JOBS:-"false"}
if [ -z "${ref_fnbase}" ]
then
  if [ "submit_jobs_to_lsf" == "true" ]
  then
    printf "Failed to find FASTA file in %s/references/%s/%s/all/fasta\n" "${ref_repository}" "${ref_organism}" "${ref_strain}" >&2
    exit 5
  else
    printf "NOTE: Failed to find FASTA file in %s/references/%s/%s/all/fasta\n" "${ref_repository}" "${ref_organism}" "${ref_strain}"
  fi
fi

########################################################################
# create the directory structure for the reanalysis
#  (then make sure your input data is in the correct place under inputs)
########################################################################
export create_work_area=${P4C_REANALYSIS_CREATE_WORK_AREA:-"false"}
if [ "${create_work_area}" == "true" ]
then
  printf "\nCreating work area\n"
  mkdir -pv "${base}"/logs  # if using LSF
  mkdir -pv "${base}"/lsf_logs  # if using LSF
  mkdir -pv "${base}"/config  # supplementary config (override/supplement p4 parameters supplied in container)
  mkdir -pv {"${workarea}","${inputs}","${outputs}"}/"${sample_name}"

  export zero_params_overrides="${base}/config/zero_params_overrides.json"
  echo -n '{}' > ${zero_params_overrides} # default of no overrides
else
  printf 'NOTE: For work area creation, set P4C_REANALYSIS_CREATE_WORK_AREA to "true"\n'
fi
export params_overrides=${P4C_REANALYSIS_PARAMS_OVERRIDES:-${zero_params_overrides}}

export prepare_inputs=${P4C_REANALYSIS_PREPARE_INPUTS:-"false"}
if [ ${prepare_inputs} == "true" ]
then
  printf "\nPreparing inputs\n"
  if [ "${input_name:0:6}" == "irods:" ]
  then
    trimmed_input_name=${input_name:6}
    if ! iget -v "${trimmed_input_name}" "${base}"/inputs/"${sample_name}"
    then
      printf "Failed to retrieve %s from iRODS to input area %s/inputs/%s\n" "${trimmed_input_name}" "${base}" "${sample_name}" >&2
      exit 6
    fi
  else
    if ! cp -iv "${input_name}" "${base}"/inputs/"${sample_name}"/
    then
      printf "Failed to copy %s to input area %s/inputs/%s\n" "${input_name}" "${base}" "${sample_name}" >&2
      exit 6
    fi
  fi
  input_base_name=$(basename ${input_name})
else
  printf 'NOTE: For input preparation (copy to work area), set P4C_REANALYSIS_PREPARE_INPUTS to "true"\n'
fi

###################
# do the reanalysis
###################

export container_url=${P4C_CONTAINER_URL:-"docker://ghcr.io/wtsi-npg/p4:latest"}
export alignment_method="bwa_mem"
export bwa_executable=${aligner}
# until container has symlink from bwa_mem2 to bwa-mem2, reset bwa_executable appropriately
if [ "${bwa_executable}" == "bwa_mem2" ]
then
  bwa_executable="bwa-mem2"
fi
export alignment_reference_genome="references/${ref_organism}/${ref_strain}/all/${aligner}/${ref_fnbase}"
export reference_genome_fasta="references/${ref_organism}/${ref_strain}/all/fasta/${ref_fnbase}"
export reference_dict="references/${ref_organism}/${ref_strain}/all/picard/${ref_fnbase}.dict"

if [ -z "${P4C_BASE_ANALYSIS}" ]
then
  printf 'Environment variable P4C_BASE_ANALYSIS must be set to specify basic analysis type to use for reanalysis (for example: "base_params_samtools_cram", "base_params_duplexseq_cram", "base_params_samtools_cram_nta", "base_params_samtools_nchs", "base_params_samtools_nchs_nta", "base_params_samtools_ysplit_nta_cram", "base_params_duplexseq_fastq" or "base_params_samtools_nchs_fastq")\n' >&2
  ((++required_parameters_missing))
fi
export base_analysis=${P4C_BASE_ANALYSIS} # top-level of work/inputs/outputs area

# default markdup optical distance suitable for NovaSeq (patterned flowcells)
export optical_distance=${P4C_MARKDUP_OPTICAL_DISTANCE:-2500}

if [ ${required_parameters_missing} -gt 0 ]
then
  printf 'Missing %d required paramters\n' ${required_parameters_missing} >&2
  exit 1
fi

if [ ${submit_jobs_to_lsf} == "true" ]
then

  if [ ! -z "${P4C_LSF_NOSUSP}" ] && [ "${P4C_LSF_NOSUSP}" == "true" ]
  then
    lsf_susp_flag=""
    printf "NOTE: Environment variable P4C_LSF_NOSUSP is set to true, LSF job will not be submitted as a suspended job\n" >&2
  else
    lsf_susp_flag="-H"
    printf "NOTE: Environment variable P4C_LSF_NOSUSP is not set to true, LSF job will be submitted as a suspended job\n" >&2
  fi

  if [ ! -z "${P4C_LSF_USER_GROUP}" ]
  then
    lsf_user_group_flag="-G ${P4C_LSF_USER_GROUP}"
  else
    lsf_user_group_flag=""
    printf "NOTE: Environment variable P4C_LSF_USER_GROUP is not set, LSF user group will not set in bsub\n" >&2
  fi

  if [ ! -z "${P4C_LSF_JOB_GROUP}" ]
  then
    lsf_job_group_flag="-g ${P4C_LSF_JOB_GROUP}"
  else
    lsf_job_group_flag=""
    printf "NOTE: Environment variable P4C_LSF_JOB_GROUP is not set, LSF job group not set in bsub\n" >&2
  fi

  export priority=${P4C_LSF_PRIORITY:-72}
  export req_mem=${P4C_LSF_REQMEM:-52000}
  export cpus=${P4C_LSF_CPUS:-12}
  export lsf_queue=${P4C_LSF_QUEUE:-"long"}

bsub \
 ${lsf_susp_flag} \
 -q ${lsf_queue} \
 ${lsf_user_group_flag} \
 ${lsf_job_group_flag} \
 -sp ${priority} \
 -M ${req_mem} \
 -n ${cpus} \
 -R "select[mem>${req_mem}] rusage[mem=${req_mem}] span[hosts=1]" \
 -o "${base}/lsf_logs/${sample_name}_ra_vanilla_%J.o" \
 -J "${sample_name}_ra_vanilla" \
 'singularity exec --bind '"${ref_repository}"':'${singularity_ref_repository}','"${inputs}"':'"${singularity_inputs}"','"${outputs}"':'"${singularity_outputs}"','"${workarea}"':'"${singularity_workarea}"' '"${container_url}"' bash -c '"'"'export REF_PATH='${singularity_ref_repository}'/cram_cache/%2s/%2s/%s:'${singularity_ref_repository}'/cram_cache_deprecated/%2s/%2s/%s:URL=http://refcache.dnapipelines.sanger.ac.uk::8000/%s && cd ${singularity_workarea}/${sample_name} && vtfp.pl -template_path /usr/local/data/vtlib -param_vals /usr/local/data/static_params/stage2_reanalysis/'${base_analysis}'.json,/usr/local/data/static_params/stage2_reanalysis/align_bwa_mem2.json,'${params_overrides}' -export_param_vals '${singularity_outputs}'/'${sample_name}'/'${sample_name}'_p4s2_pv_out.json -keys cfgdatadir,aligner_numthreads,br_numthreads_val,b2c_mt_val -vals /usr/local/data/vtlib/,6,6,6 -keys realignment_switch -vals 1 -keys ranksplit_val -vals 0 -keys post_aln_process -vals fastcollate -keys markdup_optical_distance_value -vals '${optical_distance}' -keys pp_read2tags -vals off -keys bwa_executable,alignment_method -vals '${bwa_executable}','${alignment_method}' -keys alignment_reference_genome -vals '${singularity_ref_repository}'/'${alignment_reference_genome}' -keys reference_genome_fasta -vals '${singularity_ref_repository}'/'${reference_genome_fasta}' -keys reference_dict -vals '${singularity_ref_repository}'/'${reference_dict}'  -keys incrams -vals '${singularity_inputs}'/'${sample_name}'/'${input_base_name}' -keys outdatadir -vals '${singularity_outputs}'/'${sample_name}' -keys seqchksum_orig_file -vals '${singularity_outputs}'/'${sample_name}'/'${sample_name}'.orig.seqchksum -keys rpt -vals '${sample_name}' alignment_wtsi_stage2_template.json > run_'${sample_name}'.json 2> vtfp_err_log_'${sample_name}'.txt && viv.pl -s -x -v 3 -o viv_'${sample_name}'.log run_'${sample_name}'.json'"'"''

else  # not submitting job to LSF, just report command

  printf "P4C_LSF_SUBMIT_JOBS is set to an non-true value, so not submitting LSF job\n"

  printf "\nsingularity exec --bind %s:%s,%s:%s,%s:%s,%s:%s %s bash -c export REF_PATH=%s/cram_cache/%%2s/%2s/%%s:%%s/cram_cache_deprecated/%%2s/%%2s/%%s:URL=http://refcache.dnapipelines.sanger.ac.uk::8000/%%s && cd %s/%s && vtfp.pl -template_path /usr/local/data/vtlib -param_vals /usr/local/data/static_params/stage2_reanalysis/%s.json,/usr/local/data/static_params/stage2_reanalysis/align_bwa_mem2.json,%s -export_param_vals %s/%s/%s'_p4s2_pv_out.json -keys cfgdatadir,aligner_numthreads,br_numthreads_val,b2c_mt_val -vals /usr/local/data/vtlib/,6,6,6 -keys realignment_switch -vals 1 -keys ranksplit_val -vals 0 -keys post_aln_process -vals fastcollate -keys markdup_optical_distance_value -vals %s -keys pp_read2tags -vals off -keys bwa_executable,alignment_method -vals %s,%s -keys alignment_reference_genome -vals %s/%s -keys reference_genome_fasta -vals %s/%s -keys reference_dict -vals %s/%s -keys incrams -vals %s/%s/%s -keys outdatadir -vals %s/%s -keys seqchksum_orig_file -vals %s/%s/%s.orig.seqchksum -keys rpt -vals %s alignment_wtsi_stage2_template.json > run_%s.json 2> vtfp_err_log_%s.txt && viv.pl -s -x -v 3 -o viv_%s.log run_%s.json\n" "${ref_repository}" "${singularity_ref_repository}" "${inputs}" "${singularity_inputs}" "${outputs}" "${singularity_outputs}" "${workarea}" "${singularity_workarea}" "${container_url}" "${singularity_ref_repository}" "${singularity_ref_repository}" "${singularity_workarea}" "${sample_name}" "${base_analysis}" "${params_overrides}" "${singularity_outputs}" "${sample_name}" "${sample_name}" "${optical_distance}" "${bwa_executable}" "${alignment_method}" "${singularity_ref_repository}" "${alignment_reference_genome}" "${singularity_ref_repository}" "${reference_genome_fasta}" "${singularity_ref_repository}" "${reference_dict}" "${singularity_inputs}" "${sample_name}" "${input_base_name}" "${singularity_outputs}" "${sample_name}" "${singularity_outputs}" "${sample_name}" "${sample_name}" "${sample_name}" "${sample_name}" "${sample_name}" "${sample_name}" "${sample_name}"

fi
