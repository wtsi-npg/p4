#!/usr/bin/env bash

# Exit on error
set -e -o pipefail

# $VERSION = '0';

FTC_ROOT="${FTC_ROOT:-/path/to/ftc/base}"

. ${FTC_ROOT}/scripts/ftc_env.sh

###
# find unprocessed CLIMB upload runs (run present in upload list but no corresponding ${FTC_RUNS_DIR} entry)
###
echo "checking for unprocessed CLIMB upload runs (create submissions)"
for run in $(comm -23 <(tail -n +2 ${FTC_DOCS_DIR}/full_upload_list.master.tsv | cut -f1 | sort -u) <(find ${FTC_RUNS_DIR} -maxdepth 1 -type d -exec basename {} \; | sort))
do
  echo "creating submission for run ${run}"
  set +o pipefail
  ext_climb_base=$(ls ${FTC_CLIMB_UPLOAD_BASE}/${run}/BAM_basecalls_*/*/*/${run}*.mapped.bam | head -1 | sed -e "s~/[^/]*/[^/]*$~~")
  set -o pipefail
  if [ -s ${FTC_SUBMISSIONS_DIR}/${run}.start ]
  then
	  echo "${FTC_SUBMISSIONS_DIR}/${run}.start already exists, skipping..."
  else
    grep "^${run}" ${FTC_DOCS_DIR}/full_upload_list.master.tsv | while read r p t s
    do
      printf "%s\t%s\t%s\t%s\t%s\n" ${r} ${p} ${t} ${s} $(ls ${ext_climb_base}/*/${r}_${p}#${t}.mapped.bam)
    done > ${FTC_SUBMISSIONS_DIR}/${run}.start
  fi
done

echo "Checking submissions for dehumanising"

shopt -s nullglob
for submission_file in ${FTC_SUBMISSIONS_DIR}/*.start
do
	echo; echo "processing ${submission_file}"
	mv -v ${submission_file} ${submission_file}.submitted
	run_name=$(basename ${submission_file/.start/})
	echo "run_name is ${run_name}"
	echo "creating sample-level run directories and config files under ${FTC_RUNS_DIR}/${run_name}"
	mkdir -pv ${FTC_RUNS_DIR}/${run_name}/{config,outdata,tmp}
	while read r p t s ip
	do
		mkdir -p ${FTC_RUNS_DIR}/${run_name}/tmp/${r}_${p}#${t};
		cat ${FTC_TEMPLATE_DIR}/ftc_template_pv_in.json | sed -e "s/__RUN__/${r}/" -e "s/__POS__/${p}/" -e "s/__TAG__/${t}/" -e "s~__MAIN_INPUT__~${ip}~" > ${FTC_RUNS_DIR}/${run_name}/config/${r}_${p}#${t}_pv_in.json
		cat ${FTC_TEMPLATE_DIR}/commands4dehumanising_template.txt | sed -e "s/::RUN::/${r}/g" -e "s/::POS::/${p}/g" -e "s/::TAG::/${t}/g" >> ${FTC_RUNS_DIR}/${run_name}/config/${r}_commands4dehumanising.txt
	done < ${submission_file}.submitted

	wr add --cwd /tmp --disk 0 --retries 1 --env 'PATH=/paths/to/tools' -f ${FTC_RUNS_DIR}/${run_name}/config/${run_name}_commands4dehumanising.txt

done
