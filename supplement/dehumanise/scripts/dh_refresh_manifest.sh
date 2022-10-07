#!/usr/bin/env bash

# Exit on error
set -e -o pipefail

# $VERSION = '0';

FTC_ROOT="${FTC_ROOT:-/path/to/ftc/base}"

. ${FTC_ROOT}/scripts/ftc_env.sh

manifest_backup=$(mktemp -u -p ${FTC_DOCS_DIR} "full_upload_list.$(date +%Y%m%d%H%M%S).XXX.tsv")

if [[ ! -z "${manifest_backup}" ]] && [[ ! -e "${manifest_backup}" ]]
then
	cp -iv ${FTC_DOCS_DIR}/full_upload_list.master.tsv ${manifest_backup}

	pwd=$(perl -le "$(tail -n +2 /path/to/database/info; echo 'print $VAR1->{live_ro}->{dbpass};')")
	
	printf "select ipm.id_run,ipm.position,ipm.tag_index,ihpm.supplier_sample_name from iseq_product_metrics ipm,iseq_heron_product_metrics ihpm where ipm.id_iseq_product = ihpm.id_iseq_product and ihpm.climb_upload is not null\n" | mysql -P${port} -h${host} -u${user} -p${pwd} mlwarehouse | sort -nk1,1 -nk2,2 -nk3,3 > ${FTC_DOCS_DIR}/full_upload_list.master.tsv

else
	echo "Manifest refresh failed"
fi
