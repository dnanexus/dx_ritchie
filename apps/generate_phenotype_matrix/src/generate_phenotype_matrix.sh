#!/bin/bash
# generate_phenotype_matrix 0.0.1
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
#asdsds
# See https://wiki.dnanexus.com/Developer-Portal for tutorials on how
# to modify this file.
set -x
set -o pipefail
main() {

    #echo "Value of input_data: '$input_data'"
    echo "Value of sql_file: '$sql_file'"
    echo "Value of case_filter: '$case_filter'"
    echo "Value of count_filter: '$count_filter'"
    echo "Value of count_filter: '$freeze'"
    

    # The following line(s) use the dx command-line tool to download your file
    # inputs to the local file system using variable names for the filenames. To
    # recover the original filenames, you can use the output of "dx describe
    # "$variable" --name".

    if [ -n "$sql_file" ]
    then
        dx download "$sql_file" -o sql_file
    fi

	echo ".load /usr/lib/sqlite3/pcre.so" > regex_lib_path.txt

    # Fill in your application code here.
    #
    # To report any recognized errors in the correct format in
    # $HOME/job_error.json and exit this script, you can use the
    # dx-jobutil-report-error utility as follows:
    #
    #   dx-jobutil-report-error "My error message"
    #
    # Note however that this entire bash script is executed with -e
    # when running in the cloud, so any line which returns a nonzero
    # exit code will prematurely exit the script; if no error was
    # reported in the job_error.json file, then the failure reason
    # will be AppInternalError with a generic error message.
	ls -l
	mkdir -p output_files
    cd output_files
	ls -l
	
	freeze=$(echo ${freeze} | sed 's/K//g')
	if $three_digit_rollup
	then
		icd_tbl="icd9_3d_code_count"
	else
		icd_tbl="icd9_5d_code_count"
	fi

	# If select list of ICD-9 code provided
	code_list=""
	if [ -n "$select_icd" ]
	then
		select_icd_reformat=$(echo $select_icd | sed 's/^/"/g' | sed 's/,/","/g' | sed 's/$/"/g')
		code_list="icd9_code IN (${select_icd_reformat}) and"
	fi
	
echo "$icd9_code_matrix"

	#Generate ICD9 Case-Control matrix	
	if [ "$icd9_code_matrix" == true ] || [ "$three_digit_rollup" == true];
	then
		#if $three_digit_rollup
		#then
			# Query to create case-control matrix
		sqlite3 -init ../regex_lib_path.txt ../sql_file \
		"select 'Geisinger', \
		rgn_id, \
		case when pt_id=-1 \
		then group_concat(distinct icd9_code) \
		else group_concat( \
			case when icd9_count>=${count_filter} \
			then 1 \
			else \
				case when icd9_count<${count_filter} and icd9_count>0 \
				then 'NA' \
				else 0 end \
			end) \
		end as icd9_code \
		from ( \
		select pt_id \
		from ${icd_tbl} \
		join freeze_${freeze}_demographics using(pt_id) \
		group by pt_id) as a \
		cross join \
		(select icd9_code from ${icd_tbl} c \
		join freeze_${freeze}_demographics using(pt_id) \
		where \
		${code_list} \
		icd9_count>=${count_filter} \
		and icd9_code regexp '^[0-9].*' \
		group by icd9_code \
		having count(distinct pt_id)>=${case_filter} \
		order by icd9_code) as b \
		left join ${icd_tbl} as c \
		using(pt_id, icd9_code) \
		join freeze_${freeze}_demographics \
		using(pt_id) \
		group by rgn_id" > icd9_out.txt
		
		
		cat icd9_out.txt | sed 's/|/\t/g' | sed 's/,/\t/g' | sed '1 s/^Geisinger\t/fid\tiid/g' > ${icd9_out_prefix}
	fi


	#Generate Clinical Lab matrix
	if [ "$clinical_lab_matrix" == true ];
	then
		echo  ${clinical_lab_out_prefix}
		sqlite3 -init ../regex_lib_path.txt ../sql_file \
		"select 'Geisinger' as fid, \
		rgn_id as iid, \
		case when pt_id=-1 \
		then group_concat(lab_name) \
		else group_concat(coalesce(median_lab,'NA')) end as lab \
		from ( \
		select distinct pt_id \
		from clinical_lab_data \
		join \
		freeze_${freeze}_demographics \
		using(pt_id)) as a \
		cross join ( \
		select distinct lab_name \
		from clinical_lab_data \
		order by lab_name) as b \
		left join \
		clinical_lab_data \
		using(pt_id, lab_name) \
		join \
		freeze_${freeze}_demographics \
		using(pt_id) where lab_name!='X' \
		group by rgn_id" > clinical_lab_out
		
		sed 's/ /_/g' clinical_lab_out | sed 's/|/\t/g' | sed 's/,/\t/g' | sed '1 s/^Geisinger\t/fid\tiid/g' > ${clinical_lab_out_prefix}
	fi

	# Generate covariate file
	sys_date=$(date +"%Y")
	
	if [ -n "$cont_covariate" ]
	then
		query=$(echo ${cont_covariate[*]} | sed 's/ /,/g')
		echo "fid,iid,$query" | sed 's/,/\t/g' > ${cont_covariate_out_prefix}
		
	if [[ "${cont_covariate[age]}" ]]
	then
		echo "true"
		query=$(echo $query | sed "s/age,/$sys_date\-substr(birth_date,1,4) as age,/g") 
		echo ${query}
	fi	
		
	if [[ "${cont_covariate[age^2]}" ]]
	then
		echo "true"
		query=$(echo $query | sed "s/age\^2/($sys_date\-substr(birth_date,1,4))*($sys_date-substr(birth_date,1,4)) as \`age\^2\`/g") 
		echo ${query}
	fi
	
	for i in "${cont_covariate[@]}"
	do
    		if [ "$i" == "pc1" ] ; then
        	 pca_table="join freeze_${freeze}_pca using(rgn_id)"
    		fi
	done
	
	#if [[ ${cont_covariate["pc1"]} ]];
        #then
       # 	pca_table="join freeze_${freeze}_pca using(rgn_id)"
       # fi



		sqlite3 -init ../regex_lib_path.txt ../sql_file \
		"select 'Geisinger' as fid, \
		rgn_id as iid, \
		${query} \
		from	\
		freeze_${freeze}_demographics \
		${pca_table} where sex!='Unknown' and bmi!='' and rgn_id!=''"> cont_covariate_out.txt
		
		sed 's/|/\t/g' cont_covariate_out.txt >> ${cont_covariate_out_prefix}
	fi
	
	if [ -n "$cat_covariate" ] 
	then
		query=$(echo ${cat_covariate[*]} | sed 's/ /,/g')
		echo "fid,iid,$query" | sed 's/,/\t/g' > ${cat_covariate_out_prefix}
		
		sqlite3 -init ../regex_lib_path.txt ../sql_file \
		"select 'Geisinger' as fid, \
		rgn_id as iid, \
		${query} \
		from \
		freeze_${freeze}_demographics where sex!='Unknown' and bmi!='' and rgn_id!=''"  > cat_covariate_out.txt
		
		sed 's/|/\t/g' cat_covariate_out.txt| sed 's/ /_/g' >> ${cat_covariate_out_prefix}
	fi

    # The following line(s) use the dx command-line tool to upload your file
    # outputs after you have created them on the local file system.  It assumes
    # that you have used the output field name for the filename for each output,
    # but you can change that behavior to suit your needs.  Run "dx upload -h"
    # to see more options to set metadata.
	
	if [ -e "${icd9_out_prefix}" ]
	then
    icd9_out=$(dx upload ${icd9_out_prefix} --brief)
    dx-jobutil-add-output icd9_out "$icd9_out" --class=file
	fi	
	
    if [ -e "${clinical_lab_out_prefix}" ]
    then
    	clinical_out=$(dx upload ${clinical_lab_out_prefix} --brief)
        dx-jobutil-add-output clinical_out "$clinical_out" --class=file
    fi
    
    if [ -e "${cont_covariate_out_prefix}" ]
    then
    	cont_covariate_out=$(dx upload ${cont_covariate_out_prefix} --brief)
    	dx-jobutil-add-output cont_covariate_out "$cont_covariate_out" --class=file
    fi
    
    if [ -e "${cat_covariate_out_prefix}" ]
    then
    	cat_covariate_out=$(dx upload ${cat_covariate_out_prefix} --brief)
    	dx-jobutil-add-output cat_covariate_out "$cat_covariate_out" --class=file
    fi     
    
}
