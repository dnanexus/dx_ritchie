#!/bin/bash
# call_bqsr 0.0.1
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

# install GNU parallel!
#sudo sed -i 's/^# *\(deb .*backports.*\)$/\1/' /etc/apt/sources.list
sudo apt-get update
sudo apt-get install --yes parallel

# GATK 3.4 requires java-7, GATK 3.6 requires java-8
# Deleted from json:       { "name": "openjdk-7-jre-headless" },

if [ "$gatk_version" == "3.4-46" ]
then
	sudo apt-get install --yes openjdk-7-jre-headless
else
	echo "deb http://us.archive.ubuntu.com/ubuntu vivid main restricted universe multiverse " >> /etc/apt/sources.list
	sudo apt-get update
	sudo apt-get install --yes openjdk-8-jre-headless
fi

function parallel_download() {
#	set -x
	cd $2
	dx download "$1"
	cd -
}
export -f parallel_download

function call_bqsr(){

#	set -x

	bam_in=$1
	WKDIR=$2
	N_PROC=$4
	RERUN_FILE=$5
	TARGET_FN=$6
	PADDING=$7
	TARGET_CMD=""
	if test "$TARGET_FN"; then
		TARGET_CMD="-L $TARGET_FN"
		if [ "$PADDING" ] && [ "$PADDING" -ne 0 ]; then
			TARGET_CMD="$TARGET_CMD -ip $PADDING"
		fi
	fi
	cd $WKDIR

	fn_base="$(echo $bam_in | sed -e 's/\.bam$//' -e 's|.*/||' )"

	# If I don't have the bam_in, it must be on DNANexus...
	if test -z "$(ls $bam_in)"; then
		# get the bam
		fn_base=$(dx describe --name "$bam_in" | sed 's/\.bam$//')
		dx download "$bam_in" -o $fn_base.bam
	fi

	# if the index doesn't exist, create it
	if test -z "$(ls $fn_base.bai)"; then
		samtools index $fn_base.bam $fn_base.bai
	fi

	TOT_MEM=$(free -k | grep "Mem" | awk '{print $2}')

	ulimit -m $((TOT_MEM * 9 / (N_PROC * 10) ))

	LOG_FN=$(mktemp)

	java -d64 -Xms512m -Xmx$((TOT_MEM * 9 / (N_PROC * 10) ))k -jar  /usr/share/GATK/GenomeAnalysisTK.jar \
	-T BaseRecalibrator \
	-R /usr/share/GATK/resources/build.fasta \
	-I $fn_base.bam $TARGET_CMD \
	-knownSites /usr/share/GATK/resources/dbsnp.vcf.gz \
	-knownSites /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.vcf.gz \
	-o $WKDIR/$fn_base.table >$LOG_FN 2>&1

	if test "$?" -eq 0; then
		BQSR_DXFN=$(dx upload "$WKDIR/$fn_base.table" --brief)
		echo "$BQSR_DXFN" >> $3
	else
		echo "Error running sample ${fn_base} with $N_PROC simultaneous jobs" | dx-log-stream -l critical -s DX_APP
		echo "BQSR Error.  Log file follows"
		cat $LOG_FN
		echo "$bam_in" >> $RERUN_FILE
	fi

	# Go ahead and delete the BAM file; I'm done with it now!
	rm $fn_base.bam
	rm $LOG_FN


}
export -f call_bqsr

main() {

	export SHELL="/bin/bash"

    echo "Value of bam: '${bam[@]}'"
    echo "Value of bam_idx: '${bam_idx[@]}'"
    echo "Value of target: '$target'"
    echo "Value of padding: '$padding'"

    # The following line(s) use the dx command-line tool to download your file
    # inputs to the local file system using variable names for the filenames. To
    # recover the original filenames, you can use the output of "dx describe
    # "$variable" --name".

    TARGET_FN=""

    if [ -n "$target" ]; then
    	TARGET_FN="$PWD/target.bed"
    	dx download "$target" -o target.bed
    else
    	# make sure $padding is unset here
    	padding=
    fi

	WKDIR=$(mktemp -d)
	DXBAM_LIST=$(mktemp)
	DXBAI_LIST=$(mktemp)

	cd $WKDIR

	# Download the BAM index files (in parallel)
	for i in "${!bam_idx[@]}"; do
		echo "${bam_idx[$i]}" >> $DXBAI_LIST
	done

	parallel -j $(nproc --all) -u --gnu parallel_download :::: $DXBAI_LIST ::: $WKDIR

	# Ensure they are corerctly named
	for f in $(ls *.bai); do
		mv $f $(echo $f | sed 's/\.ba\(m\.ba\)*i$/.bai/') || true
	done

	for i in "${!bam[@]}"; do
		echo "${bam[$i]}" >> $DXBAM_LIST
	done

	# get the resources we need in /usr/share/GATK
	sudo mkdir -p /usr/share/GATK/resources
	sudo chmod -R a+rwX /usr/share/GATK

	if [ "$gatk_version" == "3.4-46" ]
	then
		dx download "$DX_RESOURCES_ID:/GATK/jar/GenomeAnalysisTK-3.4-46.jar" -o /usr/share/GATK/GenomeAnalysisTK.jar
	else
		dx download "$DX_RESOURCES_ID:/GATK/jar/GenomeAnalysisTK-3.6.jar" -o /usr/share/GATK/GenomeAnalysisTK.jar
	fi

	if [ "$build_version" == "b37_decoy" ]
	then
		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta" -o /usr/share/GATK/resources/build.fasta
		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta.fai" -o /usr/share/GATK/resources/build.fasta.fai
		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.dict" -o /usr/share/GATK/resources/build.dict

		dx download "$DX_RESOURCES_ID:/GATK/resources/dbsnp_137.b37.vcf.gz" -o /usr/share/GATK/resources/dbsnp.vcf.gz
		dx download "$DX_RESOURCES_ID:/GATK/resources/dbsnp_137.b37.vcf.gz.tbi"  -o /usr/share/GATK/resources/dbsnp.vcf.gz.tbi
		dx download "$DX_RESOURCES_ID:/GATK/resources/Mills_and_1000G_gold_standard.indels.b37.vcf.gz" -o /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.vcf.gz
		dx download "$DX_RESOURCES_ID:/GATK/resources/Mills_and_1000G_gold_standard.indels.b37.vcf.gz.tbi" -o /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.vcf.gz.tbi
	else
		if [ "$gatk_version" == "3.4-46" ]
		then
			dx-jobutil-report-error "GATK verison 3.4-46 will not run b38!"
			echo "ERROR!"
			echo "ERROR!"
			echo "GATK verison 3.4-46 will not run b38"
			echo "ERROR!"
			echo "ERROR!"
			exit
			exit
		else
			dx download "$DX_RESOURCES_ID:/GATK/resources/h38flat.fasta-index.tar.gz.genome.fa" -o /usr/share/GATK/resources/build.fasta
			dx download "$DX_RESOURCES_ID:/GATK/resources/h38flat.fasta-index.tar.gz.genome.fa.fai" -o /usr/share/GATK/resources/build.fasta.fai
			dx download "$DX_RESOURCES_ID:/GATK/resources/h38flat.fasta-index.tar.gz.genome.dict" -o /usr/share/GATK/resources/build.dict

			dx download "$DX_RESOURCES_ID:/GATK/resources/dbsnp_144.hg38.chr.vcf.gz" -o /usr/share/GATK/resources/dbsnp.vcf.gz
			dx download "$DX_RESOURCES_ID:/GATK/resources/dbsnp_144.hg38.chr.vcf.gz.tbi"  -o /usr/share/GATK/resources/dbsnp.vcf.gz.tbi
			dx download "$DX_RESOURCES_ID:/GATK/resources/Mills_and_1000G_gold_standard.indels.hg38.chr.vcf.gz" -o /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.vcf.gz
			dx download "$DX_RESOURCES_ID:/GATK/resources/Mills_and_1000G_gold_standard.indels.hg38.chr.vcf.gz.tbi" -o /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.vcf.gz.tbi

		fi

	fi

	#dx download "$DX_RESOURCES_ID:/GATK/jar/GenomeAnalysisTK-3.4-46.jar" -o /usr/share/GATK/GenomeAnalysisTK-3.4-46.jar
	#dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta" -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta
	#dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta.fai" -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta.fai
	#dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.dict" -o /usr/share/GATK/resources/human_g1k_v37_decoy.dict

	#dx download "$DX_RESOURCES_ID:/GATK/resources/dbsnp_137.b37.vcf.gz" -o /usr/share/GATK/resources/dbsnp_137.b37.vcf.gz
	#dx download "$DX_RESOURCES_ID:/GATK/resources/dbsnp_137.b37.vcf.gz.tbi"  -o /usr/share/GATK/resources/dbsnp_137.b37.vcf.gz.tbi
	#dx download "$DX_RESOURCES_ID:/GATK/resources/Mills_and_1000G_gold_standard.indels.b37.vcf.gz" -o /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.b37.vcf.gz
	#dx download "$DX_RESOURCES_ID:/GATK/resources/Mills_and_1000G_gold_standard.indels.b37.vcf.gz.tbi" -o /usr/share/GATK/resources/Mills_and_1000G_gold_standard.indels.b37.vcf.gz.tbi

	DX_BQSR_LIST=$(mktemp)

	N_CHUNKS=$(cat $DXBAM_LIST | wc -l)
	RERUN_FILE=$(mktemp)
	N_RUNS=1
	N_CORES=$(nproc)
	N_JOBS=1

	# each run, we will decrease the number of cores available until we're at a single core at a time (using ALL the memory)
	while test $N_CHUNKS -gt 0 -a $N_JOBS -gt 0; do

		N_JOBS=$(echo "$N_CORES/2^($N_RUNS - 1)" | bc)
		# make sure we have a minimum of 1 job, please!
		N_JOBS=$((N_JOBS > 0 ? N_JOBS : 1))

		parallel -j $N_JOBS -u --gnu call_bqsr :::: $DXBAM_LIST ::: $WKDIR ::: $DX_BQSR_LIST ::: $N_JOBS ::: $RERUN_FILE ::: $TARGET_FN ::: $padding

		PREV_CHUNKS=$N_CHUNKS
		N_CHUNKS=$(cat $RERUN_FILE | wc -l)
		mv $RERUN_FILE $DXBAM_LIST
		RERUN_FILE=$(mktemp)
		N_RUNS=$((N_RUNS + 1))
		# just to make N_JOBS 0 at the conditional when we ran only a single job!
		N_JOBS=$((N_JOBS - 1))
	done

	# We need to be certain that nothing remains to be merged!
	if test "$N_CHUNKS" -ne 0; then
		echo "WARNING: Some samples not called, see CRITICAL log for details" | dx-log-stream -l critical -s DX_APP
	fi

	while read bqsr_fn; do
		dx-jobutil-add-output bqsr_tables "$bqsr_fn" --class=array:file
	done < $DX_BQSR_LIST

}
