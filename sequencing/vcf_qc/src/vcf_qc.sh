#!/bin/bash
# vcf_qc 0.0.1
# Generated by dx-app-wizard.
#
# Basic execution pattern: Your app will run on a single machine from
# beginning to end.
#
# Your job's input variables (if any) will be loaded as environment
# variables before this script runs.  Any array inputs will be loaded
# as bash arrays.
#
# Any code outside of main() (or any entry point you may add) is
# ALWAYS executed, followed by running the entry point itself.
#
# See https://wiki.dnanexus.com/Developer-Portal for tutorials on how
# to modify this file.

set -x

echo "deb http://us.archive.ubuntu.com/ubuntu vivid main restricted universe multiverse " >> /etc/apt/sources.list
sudo apt-get update
sudo apt-get install --yes openjdk-8-jre-headless

main() {


    echo "Value of vcf_fn: '$vcf_fn'"
    echo "Value of vcfidx_fn: '$vcfidx_fn'"
    echo "Value of SNP_tranches: '$SNP_tranches'"
    echo "Value of SNP_recal: '$SNP_recal'"
    echo "Value of INDEL_tranches: '$INDEL_tranches'"
    echo "Value of INDEL_recal: '$INDEL_recal'"
    echo "Value of SNP_ts: '$SNP_ts'"
    echo "Value of INDEL_ts: '$INDEL_ts'"
    echo "Value of addl_filter: '$addl_filter'"

	# Sanity check - make sure vcf + vcfidx have same # of elements
	if test "${#vcfidx_fn[@]}" -ne "${#vcf_fn[@]}"; then
		dx-jobutil-report-error "ERROR: Number of VCFs and VCF indexes do NOT match!"
	fi

	# first, we need to match up the VCF and tabix index files
	# To do that, we'll get files of filename -> dxfile ID
	VCF_LIST=$(mktemp)
	for i in "${!vcf_fn[@]}"; do
		dx describe --json "${vcf_fn[$i]}" | jq -r ".name,.id" | tr '\n' '\t' | sed 's/\t$/\n/' >> $VCF_LIST
	done

	VCFIDX_LIST=$(mktemp)
	for i in "${!vcfidx_fn[@]}"; do
		dx describe --json "${vcfidx_fn[$i]}" | jq -r ".name,.id" | tr '\n' '\t' | sed -e 's/\t$/\n/' -e 's/\.tbi\t/\t/' >> $VCFIDX_LIST
	done

	# Now, get the prefix (strip off any .tbi) and join them
	JOINT_LIST=$(mktemp)
	join -t$'\t' -j1 <(sort -k1,1 $VCF_LIST) <(sort -k1,1 $VCFIDX_LIST) > $JOINT_LIST

	# Ensure that we still have the same number of files; throw an error if not
	if test $(cat $JOINT_LIST | wc -l) -ne "${#vcf_fn[@]}"; then
		dx-jobutil-report-error "ERROR: VCF files and indexes do not match!"
	fi

	JOB_ARGS=""
	if test "$target" -a "$max_sz"; then
		if test -n "$padding"; then
			padding=0
		fi

		JOB_ARGS="-itarget:file=$(dx describe --json "$target" | jq -r .id) -imax_sz:int=$max_sz -ipadding:int=$padding"
	fi

	# and loop through the file, submitting sub-jobs
	while read VCF_LINE; do
		VCF_DXFN=$(echo "$VCF_LINE" | cut -f2)
		VCFIDX_DXFN=$(echo "$VCF_LINE" | cut -f3)

		SUBJOB=$(dx-jobutil-new-job run_qc $JOB_ARGS -ivcf_fn:file="$VCF_DXFN" -ivcfidx_fn:file="$VCFIDX_DXFN" -iSNP_tranches="$SNP_tranches" -iSNP_recal="$SNP_recal" -iINDEL_tranches="$INDEL_tranches" -iINDEL_recal="$INDEL_recal" -iSNP_ts="$SNP_ts" -iINDEL_ts="$INDEL_ts" -iaddl_filter="$addl_filter")

		# for each subjob, add the output to our array
    	dx-jobutil-add-output vcf_out --array "$SUBJOB:vcf_out" --class=jobref
	    dx-jobutil-add-output vcfidx_out --array "$SUBJOB:vcfidx_out" --class=jobref

	done < $JOINT_LIST

}


run_qc() {

    echo "Value of vcf_fn: '$vcf_fn'"
    echo "Value of vcfidx_fn: '$vcfidx_fn'"
    echo "Value of SNP_tranches: '$SNP_tranches'"
    echo "Value of SNP_recal: '$SNP_recal'"
    echo "Value of INDEL_tranches: '$INDEL_tranches'"
    echo "Value of INDEL_recal: '$INDEL_recal'"
    echo "Value of SNP_ts: '$SNP_ts'"
    echo "Value of INDEL_ts: '$INDEL_ts'"
    echo "Value of addl_filter: '$addl_filter'"

    # The following line(s) use the dx command-line tool to download your file
    # inputs to the local file system using variable names for the filenames. To
    # recover the original filenames, you can use the output of "dx describe
    # "$variable" --name".

    dx download "$vcfidx_fn" -o raw.vcf.gz.tbi
	PREFIX=$(dx describe --name "$vcf_fn" | sed 's/\.vcf.\(gz\)*$//')
    SUBJOBS=0

	if test -z "$INTERVAL" -a "$target" -a "$max_sz"; then

		if test "$(dx describe --json "$vcf_fn" | jq -r .size)" -gt "$((max_sz * 1000 * 1000))"; then
			SUBJOBS=1
			CAT_ARGS=""
			for chr in $(tabix -l raw.vcf.gz); do
				EST_SZ=$(estimate_size.py -i raw.vcf.gz.tbi -L $chr -H)
				N_JOBS=$((EST_SZ / (max_sz * 1000 * 1000) + 1))

				TGT_FN=$(mktemp)
				dx cat "$target" | grep "^$chr\W" | interval_pad.py $padding $N_JOBS > $TGT_FN

				for n in $(cut -d: -f1 $TGT_FN | uniq); do
					INTV_FN=$(mktemp)
					grep "^$n:" $TGT_FN | cut -d: -f2 > $INTV_FN
					START=$(($(head -1 $INTV_FN | cut -f2 | tr -d '\n') - padding))
					STOP=$(($(tail -1 $INTV_FN | cut -f3 | tr -d '\n') + padding))

					INTV="$chr:$START-$STOP"
					rm $INTV_FN

					new_job=$(dx-jobutil-new-job run_qc -ivcf_fn="$vcf_fn" -ivcfidx_fn="$vcfidx_fn" -iSNP_tranches="$SNP_tranches" -iSNP_recal="$SNP_recal" -iINDEL_tranches="$INDEL_tranches" -iINDEL_recal="$INDEL_recal" -iSNP_ts="$SNP_ts" -iINDEL_ts="$INDEL_ts" -iaddl_filter="$addl_filter" -iINTERVAL:string="$INTV")
					CAT_ARGS="$CAT_ARGS -ivcfidxs:array:file=${new_job}:vcfidx_out -ivcfs:array:file=${new_job}:vcf_out"
				done

				rm $TGT_FN
			done

			# run the concatenation
			cat_job=$(dx run cat_variants -iprefix="$PREFIX.filtered" $CAT_ARGS --brief --instance-type mem2_hdd2_x2)

			# dx jobutil-add-output
			dx-jobutil-add-output vcf_out "$cat_job:vcf_out" --class=jobref
			dx-jobutil-add-output vcfidx_out "$cat_job:vcfidx_out" --class=jobref
		fi


	fi

	# only continue if SUBJOB==0, which means no subjobs requested!
    if test $SUBJOBS -eq 0; then

		GATK_INTERVAL=""
		if test -z "$INTERVAL"; then
			dx download "$vcf_fn" -o raw.vcf.gz
		else
			GATK_INTERVAL="-L $INTERVAL"
			PREFIX="$PREFIX.$(echo $INTERVAL | tr ':-' '._')"
			download_part.py -i raw.vcf.gz.tbi -f "$(dx describe --json "$vcf_fn" | jq -r .id)" -H -o raw.vcf.gz $GATK_INTERVAL
			rm raw.vcf.gz.tbi
			tabix -p vcf raw.vcf.gz
		fi

		RUN_SNP_RECAL=0
		if [ -n "$SNP_tranches" ]; then
		    dx download "$SNP_tranches" -o SNP_tranches
		    if [ -n "$SNP_recal" ]; then
			    dx download "$SNP_recal" -o SNP_recal
			    RUN_SNP_RECAL=1
			fi
		fi

		RUN_INDEL_RECAL=0
		if [ -n "$INDEL_tranches" ]; then
		    dx download "$INDEL_tranches" -o INDEL_tranches
		    if [ -n "$INDEL_recal" ]; then
			    dx download "$INDEL_recal" -o INDEL_recal
			    RUN_INDEL_RECAL=1
			fi
		fi

		RUN_FILTERS=0
		if test -n "$addl_filter"; then
			RUN_FILTERS=1
		fi

		# get the resources we need in /usr/share/GATK
		sudo mkdir -p /usr/share/GATK/resources
		sudo chmod -R a+rwX /usr/share/GATK


    dx download "$DX_RESOURCES_ID:/GATK/jar/GenomeAnalysisTK-3.6.jar" -o /usr/share/GATK/GenomeAnalysisTK.jar

    if [ "$build_version" == "b37_decoy" ]
  	then
  		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta" -o /usr/share/GATK/resources/build.fasta
  		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta.fai" -o /usr/share/GATK/resources/build.fasta.fai
  		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.dict" -o /usr/share/GATK/resources/build.dict
    elif [ "$build_version" == "rgc_b38" ]
    then

      dx download "$DX_RESOURCES_ID:/GATK/resources/Homo_sapiens_assembly38.fasta" -o /usr/share/GATK/resources/build.fasta
      dx download "$DX_RESOURCES_ID:/GATK/resources/Homo_sapiens_assembly38.fasta.fai" -o /usr/share/GATK/resources/build.fasta.fai
      dx download "$DX_RESOURCES_ID:/GATK/resources/Homo_sapiens_assembly38.dict" -o /usr/share/GATK/resources/build.dict

  	else

  			dx download "$DX_RESOURCES_ID:/GATK/resources/h38flat.fasta-index.tar.gz.genome.fa" -o /usr/share/GATK/resources/build.fasta
  			dx download "$DX_RESOURCES_ID:/GATK/resources/h38flat.fasta-index.tar.gz.genome.fa.fai" -o /usr/share/GATK/resources/build.fasta.fai
  			dx download "$DX_RESOURCES_ID:/GATK/resources/h38flat.fasta-index.tar.gz.genome.dict" -o /usr/share/GATK/resources/build.dict


  	fi


		TOT_MEM=$(free -m | grep "Mem" | awk '{print $2}')
		# only ask for 90% of total system memory
		TOT_MEM=$((TOT_MEM * 9 / 10))

		BASE_VCF=raw.vcf.gz

		if test $RUN_SNP_RECAL -ne 0; then
			SNP_RECAL_DIR=$(mktemp -d)
			java -d64 -Xms512m -Xmx${TOT_MEM}m -jar /usr/share/GATK/GenomeAnalysisTK.jar \
			-T ApplyRecalibration $GATK_INTERVAL \
			-nt $(nproc --all) \
			-R /usr/share/GATK/resources/build.fasta \
			-input $BASE_VCF \
			-tranchesFile SNP_tranches \
			-recalFile SNP_recal \
			-mode SNP --ts_filter_level $SNP_ts \
			-o $SNP_RECAL_DIR/filtered.vcf.gz

			rm $BASE_VCF
			rm $BASE_VCF.tbi
			BASE_VCF=$SNP_RECAL_DIR/filtered.vcf.gz
		fi

		if test $RUN_INDEL_RECAL -ne 0; then
			INDEL_RECAL_DIR=$(mktemp -d)
			java -d64 -Xms512m -Xmx${TOT_MEM}m -jar /usr/share/GATK/GenomeAnalysisTK.jar \
			-T ApplyRecalibration $GATK_INTERVAL  \
			-nt $(nproc --all) \
			-R /usr/share/GATK/resources/build.fasta \
			-input $BASE_VCF \
			-tranchesFile INDEL_tranches \
			-recalFile INDEL_recal \
			-mode INDEL --ts_filter_level $INDEL_ts \
			-o $INDEL_RECAL_DIR/filtered.vcf.gz

			rm $BASE_VCF
			rm $BASE_VCF.tbi
			BASE_VCF=$INDEL_RECAL_DIR/filtered.vcf.gz
		fi

		if test $RUN_FILTERS -ne 0; then
			FILTER_DIR=$(mktemp -d)

			eval java -d64 -Xms512m -Xmx${TOT_MEM}m -jar /usr/share/GATK/GenomeAnalysisTK.jar $GATK_INTERVAL -T VariantFiltration -R /usr/share/GATK/resources/build.fasta -V $BASE_VCF "$addl_filter" -o $FILTER_DIR/filtered.vcf.gz

			BASE_VCF=$FILTER_DIR/filtered.vcf.gz
		fi

		OUT_DIR=$(mktemp -d)
		mv $BASE_VCF $OUT_DIR/$PREFIX.filtered.vcf.gz
		mv $BASE_VCF.tbi $OUT_DIR/$PREFIX.filtered.vcf.gz.tbi

		vcf_out=$(dx upload $OUT_DIR/$PREFIX.filtered.vcf.gz --brief)
		vcfidx_out=$(dx upload $OUT_DIR/$PREFIX.filtered.vcf.gz.tbi --brief)

		# The following line(s) use the utility dx-jobutil-add-output to format and
		# add output variables to your job's output as appropriate for the output
		# class.  Run "dx-jobutil-add-output -h" for more information on what it
		# does.

		dx-jobutil-add-output vcf_out "$vcf_out" --class=file
		dx-jobutil-add-output vcfidx_out "$vcfidx_out" --class=file
	fi
}
