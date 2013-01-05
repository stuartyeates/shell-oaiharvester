# Functions for the shell-oaiharvester.

function die {
	echo "$@" >&2
	exit 1
}

# Gets generic options from config file.
function getGenericConfig {
	local data=$1
	echo $(xsltproc --stringparam data ${data} ${INSTALLDIR}/retrieveConfig.xsl ${CONFIGFILE})
}

# Gets repository specific options from config file.
function getRepositoryConfig {
	local data=$1
	local repository=$2
	echo $(xsltproc --stringparam data ${data} --stringparam repository ${repository} ${INSTALLDIR}/retrieveConfig.xsl ${CONFIGFILE})
}

# Gets data from target.
function getTargetData {
	local data=$1
	local target=$2
	echo $(xsltproc --stringparam data ${data} ${INSTALLDIR}/retrieveData.xsl ${TMP}/${target}.xml)
}

# getRecords function
function getRecords {
	# download the oaipage
	local starttime=$(date +%s%N | cut -b1-13)
	wget ${WGET_OPTS} ${URL} -O ${TMP}/oaipage.xml
	local endtime=$(date +%s%N | cut -b1-13)
	local downloadtime=$(echo "scale=3; ($endtime - $starttime)/1000" | bc)


	# process the downloaded xml
	local starttime=$(date +%s%N | cut -b1-13)
	local conditional="${REPOSITORY_RECORDPATH}/${CONDITIONAL}"
	local count=1
	local record_count=$(getTargetData "record_count" "oaipage")

	
	while [ ${count} -le ${record_count} ]; do
		# get oai identifier and actual storage dir (based on first 2 chars of md5sum identifier)
		local identifier=$(xsltproc --stringparam data identifier --param record_nr ${count} ${INSTALLDIR}/retrieveData.xsl ${TMP}/oaipage.xml | sed s/\\//\%2F/g | sed s/\&/\%26/g | sed s/\ /\%20/g)
		local name="${identifier}"
		local namemd5=$(echo "${name}" | md5sum)
		local storedir=${namemd5:0:2}
		local path="${REPOSITORY_RECORDPATH}/${storedir}/${name}"
		
		# check if status is deleted
		local status=$(xsltproc --stringparam data headerstatus --param record_nr ${count} ${INSTALLDIR}/retrieveData.xsl ${TMP}/oaipage.xml)

		if [ "${status}" == "deleted" ]; then
			if [ ! -z ${DELETE_CMD} ]; then
				eval ${DELETE_CMD}
			fi
			rm -f "${path}" > /dev/null 2>&1
		else
			# Store temporary record
			xsltproc --param record_nr ${count} ${INSTALLDIR}/retrieveRecord.xsl ${TMP}/oaipage.xml > ${TMP}/harvested.xml

			# first parse conditional xslt if available
			if [ ! -z ${conditional} ] && [ -f ${conditional} ]; then
				if [ "$(xsltproc ${conditional} ${TMP}/harvested.xml)" == "" ]; then
					# conditional not met, delete record
					rm ${TMP}/harvested.xml
				else
					mv ${TMP}/harvested.xml ${TMP}/passed-conditional.xml
				fi
			else
				mv ${TMP}/harvested.xml ${TMP}/passed-conditional.xml
			fi

			# store record if it passed the conditional test
			if [ -f ${TMP}/passed-conditional.xml ]; then
				mkdir -p "${REPOSITORY_RECORDPATH}/${storedir}"
				mv ${TMP}/passed-conditional.xml "${path}"
				if [ ! -z ${UPDATE_CMD} ]; then
					eval ${UPDATE_CMD}
				fi
			fi

			# do translate here if translate is true
			# still to do
			#xsltproc --param record_nr ${count} retrieveRecord.xsl oaipage.xml > /tmp/record.xml
			#xsltproc modules/lom/stripUrls.xsl /tmp/record.xml > "${STORE_DIR}/${name}"
			#rm /tmp/record.xml
		fi

		count=$(( ${count} + 1 ))
	done
	
	local endtime=$(date +%s%N | cut -b1-13)
	local processtime=$(echo "scale=3; ($endtime - $starttime)/1000" | bc)


	# write logline
	echo "$(date '+%F %T'),$REPOSITORY,$record_count,$downloadtime,$processtime" >> ${LOGFILE}
}
