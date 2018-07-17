#!/bin/bash
# vcf_summary 1.0.0
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

set -ex -o pipefail

main() {
    echo "Value of vcf_fn: '$variants_vcfgz'"

    if test -z "$prefix"; then
        prefix="$variants_vcfgz_prefix"
    fi

    WKDIR=$(mktemp -d)
    cd $WKDIR
    OUTDIR=$(mktemp -d)

    # check if files is gzipped
    LOCALFN="$variants_vcfgz_prefix".vcf
    if [[ "$variants_vcfgz_name" == *.gz ]]; then
        dx download "$variants_vcfgz" -o - | zcat > $LOCALFN
    else
        dx download "$variants_vcfgz" -o $LOCALFN
    fi

        # Download biofilter + loki
        sudo mkdir /usr/share/biofilter
        sudo chmod a+rwx /usr/share/biofilter

        # Download resources from parent project
        # If this is an app, $DX_RESOURCES_ID is defined, if it's an applet, use parent project instead
        if [[ "$DX_RESOURCES_ID" != "" ]]; then
            DX_ASSETS_ID="$DX_RESOURCES_ID"
        else
            DX_ASSETS_ID="$DX_PROJECT_CONTEXT_ID"
        fi
    
        # download the entire contents of the biofilter folder
        dx download -r "$DX_ASSETS_ID:/Biofilter/"
        sudo mv ./Biofilter/2.4/* /usr/share/biofilter/

        # download LOKI DB
        dx download "$DX_ASSETS_ID:/LOKI/LOKI-20150427-noSNPs.db" -o /usr/share/biofilter/loki.db

        # Convert the chrom/pos of each position in the VCF into a biofilter-compatible chrom/pos input
        cat $LOCALFN | grep -v '^#' | cut -f1,2 | tee bf_chrpos | wc -l

        python /usr/share/biofilter/biofilter.py -k /usr/share/biofilter/loki.db -P bf_chrpos --annotate position gene --gbv 37 --stdout > bf_raw

        cat bf_raw | \
            tail -n+2 | cut -f2,4 | \
            awk 'BEGIN{pv=""; pl="";} {if($1 != pv){ if(length(pv)){ print pv "\t" pl}; pv=$1; pl=$2;} else {pl=(pl "," $2);}}  END {print pv "\t" pl;}' | \
            sed -e 's/^chr//' -e's/:/\t/' | tee bf_geneout | wc -l

        # Now, bf_geneout should be a 3-column file with chrom, pos, gene(s) (comma-separated)
        # Pass that and the unzipped VCF to our python script to calculate sample-level stats
        sample_summary.py bf_geneout <(cat $LOCALFN) | tee $OUTDIR/$prefix.sample | wc -l

        sample_stats=$(dx upload $OUTDIR/$prefix.sample --brief)
        dx-jobutil-add-output sample_stats "$sample_stats" --class=file
}
