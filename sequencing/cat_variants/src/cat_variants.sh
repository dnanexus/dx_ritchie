#!/bin/bash
# combine_variants 0.0.1
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

# install GNU parallel!
sudo sed -i 's/^# *\(deb .*backports.*\)$/\1/' /etc/apt/sources.list
sudo apt-get update
sudo apt-get install --yes parallel

set -x
export SHELL="/bin/bash"

#echo "deb http://us.archive.ubuntu.com/ubuntu vivid main restricted universe multiverse " >> /etc/apt/sources.list
#sudo apt-get update
#sudo apt-get install --yes openjdk-8-jre-headless
#sudo apt-get install --yes parallel

dx download "$DX_RESOURCES_ID:/GATK/resources/jre-8u101-linux-x64.tar.gz" -o /usr/share/jre-8u101-linux-x64.tar.gz
tar -zxvf /usr/share/jre-8u101-linux-x64.tar.gz -C /usr/share/

function download_resources() {

	# get the resources we need in /usr/share/GATK
	sudo mkdir -p /usr/share/GATK/resources
	sudo chmod -R a+rwX /usr/share/GATK

	#dx download "$DX_RESOURCES_ID:/GATK/jar/GenomeAnalysisTK-3.4-46-custom.jar" -o /usr/share/GATK/GenomeAnalysisTK-3.4-46-custom.jar
	dx download "$DX_RESOURCES_ID:/GATK/jar/GenomeAnalysisTK-3.6.jar" -o /usr/share/GATK/GenomeAnalysisTK.jar
	#dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta" -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta
	#dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta.fai" -o /usr/share/GATK/resources/human_g1k_v37_decoy.fasta.fai
	#dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.dict" -o /usr/share/GATK/resources/human_g1k_v37_decoy.dict

	if [ "$build_version" == "b37_decoy" ]
	then
		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta" -o /usr/share/GATK/resources/build.fasta
		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.fasta.fai" -o /usr/share/GATK/resources/build.fasta.fai
		dx download "$DX_RESOURCES_ID:/GATK/resources/human_g1k_v37_decoy.dict" -o /usr/share/GATK/resources/build.dict

	else

			dx download "$DX_RESOURCES_ID:/GATK/resources/h38flat.fasta-index.tar.gz.genome.fa" -o /usr/share/GATK/resources/build.fasta
			dx download "$DX_RESOURCES_ID:/GATK/resources/h38flat.fasta-index.tar.gz.genome.fa.fai" -o /usr/share/GATK/resources/build.fasta.fai
			dx download "$DX_RESOURCES_ID:/GATK/resources/h38flat.fasta-index.tar.gz.genome.dict" -o /usr/share/GATK/resources/build.dict


	fi

}

function parallel_download() {
	set -x
	cd $2
	dx download "$(dx describe --json "$1" | jq -r .id)"
	cd - >/dev/null
}
export -f parallel_download

function dl_index() {
	#set -x
	cd "$2"
	fn=$(dx describe --name "$1")
	dx download "$1" -o "$fn"
	if test -z "$(ls $fn.tbi)"; then
		tabix -p vcf $fn
	fi
	echo "$2/$fn" >> $3
}
export -f dl_index

main() {

    echo "Value of vcfs: '${vcfs[@]}'"
    echo "Value of vcfidxs: '${vcfidxs[@]}'"
    echo "Value of prefix: '$prefix'"

    if test -z "$prefix"; then
    	prefix="combined"
    else
    	prefix=$(echo "$prefix" | sed 's|/|_|g')
    fi

    # The following line(s) use the dx command-line tool to download your file
    # inputs to the local file system using variable names for the filenames. To
    # recover the original filenames, you can use the output of "dx describe
    # "$variable" --name".

	echo "Resources: $DX_RESOURCES_ID"
	# set the shell to work w/ GNU parallel
	export SHELL="/bin/bash"

	# Arguments:
	# gvcfidxs (optional)
	# array of files, each containing a "dx download"-able file, one per line
	# and the files are tbi indexes of the gvcf.gz files
	# gvcfs (mandatory)
	# array of files, as above, where each line is a single gvcf file
	# PREFIX (mandatory)
	# the prefix to use for the single resultant gvcf

	FINAL_DIR=$(mktemp -d)

	if test "$use_gatk" = "true"; then
		download_resources

		# download my gvcfidx_list
		DX_VCFIDX_LIST=$(mktemp)
		WKDIR=$(mktemp -d)

		for i in "${!vcfidxs[@]}"; do
			echo "${vcfidxs[$i]}" >> $DX_VCFIDX_LIST
		done

		cd $WKDIR

		parallel -u --gnu -j $(nproc --all) parallel_download :::: $DX_VCFIDX_LIST ::: $WKDIR

		# OK, now all of the gvcf indexes are in $WKDIR, time to download
		# all of the GVCFs in parallel
		DX_VCF_LIST=$(mktemp)
		for i in "${!vcfs[@]}"; do
			echo "${vcfs[$i]}" >> $DX_VCF_LIST
		done

		# download (and index if necessary) all of the gVCFs
		VCF_LIST=$(mktemp)
		parallel -u --gnu -j $(nproc --all) dl_index :::: $DX_VCF_LIST ::: $WKDIR ::: $VCF_LIST

		# Now, merge the gVCFs into a single gVCF
		TOT_MEM=$(free -m | grep "Mem" | awk '{print $2}')
		/usr/share/jre1.8.0_101/bin/java -d64 -Xms512m -Xmx$((TOT_MEM * 9 / 10))m  -cp /usr/share/GATK/GenomeAnalysisTK.jar org.broadinstitute.gatk.tools.CatVariants \
		-R /usr/share/GATK/resources/build.fasta \
		$(cat $VCF_LIST | sed 's/^/-V /' | tr '\n' ' ') \
		-out $FINAL_DIR/$prefix.vcf.gz

	else
		# Use the custom vcf_cat.py script
		WKDIR=$(mktemp -d)
		dict_dxid=$(dx describe --json "$DX_RESOURCES_ID:/GATK/resources/build.dict" | jq -r .id)

		ARGS=""
		for i in "${!vcfs[@]}"; do
			ARGS="$ARGS -V $(dx describe "${vcfs[$i]}" --json | jq -r .id)"
		done

		cat_vcf.py -D $dict_dxid $ARGS -o $FINAL_DIR/$prefix.vcf.gz
		tabix -p vcf $FINAL_DIR/$prefix.vcf.gz
	fi

	# and upload it and we're done!
	DX_VCF_UPLOAD=$(dx upload "$FINAL_DIR/$prefix.vcf.gz" --brief)
	DX_VCFIDX_UPLOAD=$(dx upload "$FINAL_DIR/$prefix.vcf.gz.tbi" --brief)

	dx-jobutil-add-output vcf_out $DX_VCF_UPLOAD --class=file
	dx-jobutil-add-output vcfidx_out $DX_VCFIDX_UPLOAD --class=file
}
