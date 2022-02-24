#!/usr/bin/env bash

# Exit on error
set -e -o pipefail

# $VERSION = '0';
FTC_ROOT="${FTC_ROOT:-/path/to/ftc/base}"
FTC_PUBLISH_DIR="${FTC_PUBLISH_DIR:-/path/to/publish/directory}"

. ${FTC_ROOT}/scripts/ftc_env.sh

for run in "$@"
do
  if [ -d ${FTC_PUBLISH_DIR}/${run} ]
  then
    echo "${FTC_PUBLISH_DIR}/${run} exists, skipping..."
  elif [ $(grep -c "^${run}" ${FTC_DOCS_DIR}/full_upload_list.master.tsv) -eq 0 ]
  then
    echo "Run ${run} not in ${FTC_DOCS_DIR}/full_upload_list.master.tsv, skipping..."
  else
    echo "Publishing ${run} to ${FTC_PUBLISH_DIR}/${run}"
    mkdir -v ${FTC_PUBLISH_DIR}/${run} \
    && grep "^${run}" ${FTC_DOCS_DIR}/full_upload_list.master.tsv | cut -f1-3 | while read r p t
       do
         ln -vt ${FTC_PUBLISH_DIR}/${run} "${FTC_RUNS_DIR}/${run}/outdata/${r}_${p}#${t}.cram"
       done \
    && chmod -c a-w ${FTC_PUBLISH_DIR}/${run}/*.cram \
    && cat <(printf "#Run\tLane\tTag\tSampleName\n") <(grep "^${run}" ${FTC_DOCS_DIR}/full_upload_list.master.tsv) > ${FTC_PUBLISH_DIR}/${run}/sample_list_${run}.tsv
  fi
done
