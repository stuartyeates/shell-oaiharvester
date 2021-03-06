# Functions for the shell-oaiharvester.

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

# Checks if downloaded oaipage is valid for xslt processing.
function checkValidXml {
	local url=$1
	local response=$(xsltproc --novalid --stringparam data responsedate ${INSTALLDIR}/retrieveData.xsl ${TMP}/oaipage.xml)

	if [ "${response}" == "" ]; then
		die "No responseDate found in source, probably not OAI-PMH: ${url}"
	fi
}

# returns http status code
function getHttpStatus {
	local url=$1
	echo $(curl ${CURL_OPTS} -s -o /dev/null -w "%{http_code}" "${url}")
}

# getRecords function
function getRecords {
	# download the oaipage
	local starttime=$(date +%s%N | cut -b1-13)
	curl ${CURL_OPTS} ${URL} -o ${TMP}/oaipage.xml
	local endtime=$(date +%s%N | cut -b1-13)
	local downloadtime=$(echo "scale=3; ($endtime - $starttime)/1000" | bc)

	# process the downloaded xml
	checkValidXml ${URL}
	local starttime=$(date +%s%N | cut -b1-13)
	local conditional="${REPOSITORY_RECORDPATH}/${CONDITIONAL}"
	local count=1
	local record_count=$(getTargetData "record_count" "oaipage")

	while [ ${count} -le ${record_count} ]; do
		# get oai identifier and actual storage dir (based on first 2 chars of md5sum identifier)
		local identifier=$(xsltproc --stringparam data identifier --param record_nr ${count} ${INSTALLDIR}/retrieveData.xsl ${TMP}/oaipage.xml | sed s/\\//\%2F/g | sed s/\&/\%26/g | sed s/\ /\%20/g)
		local filename="${identifier}"
		[ "${COMPRESS}" == "true" ] && filename="${filename}.xz"
		local namemd5=$(echo "${identifier}" | md5sum)
		local storedir=${namemd5:0:2}
		local path="${REPOSITORY_RECORDPATH}/${storedir}/${filename}"
		
		# check if status is deleted
		local status=$(xsltproc --stringparam data headerstatus --param record_nr ${count} ${INSTALLDIR}/retrieveData.xsl ${TMP}/oaipage.xml)

		if [ "${status}" == "deleted" ]; then
			if [ ! -z "${REPOSITORY_DELETE_CMD}" ]; then
				eval ${REPOSITORY_DELETE_CMD}
			fi

			if [ ! -z "${DELETE_CMD}" ]; then
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

				if [ "${COMPRESS}" == "false" ]; then
					mv ${TMP}/passed-conditional.xml "${path}"
				elif [ "${COMPRESS}" == "true" ]; then
					 xz -c ${TMP}/passed-conditional.xml > "${path}"
					 rm ${TMP}/passed-conditional.xml
				fi

				if [ ! -z "${REPOSITORY_UPDATE_CMD}" ]; then
					eval ${REPOSITORY_UPDATE_CMD}
				fi

				if [ ! -z "${UPDATE_CMD}" ]; then
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
	echo "$(date '+%F %T'),$REPOSITORY,$URL,$record_count,$downloadtime,$processtime" >> ${LOGFILE}
}

function testRepository {
	echo "# checking status code"
	statuscode=$(getHttpStatus "${BASEURL}?verb=Identify")
	if [ "${statuscode}" != "200" ]; then
		die "received status code ${statuscode}, exiting"
	else
		echo "status ok"
	fi

	echo
	echo "# Downloading pages:"
	curl ${CURL_OPTS} "${BASEURL}?verb=Identify" -o "${TMP}/identify.xml"
	curl ${CURL_OPTS} "${BASEURL}?verb=ListMetadataFormats" -o "${TMP}/listmetadataformats.xml"

	if [ -z ${SET} ]; then
		curl ${CURL_OPTS} "${BASEURL}?verb=ListRecords&metadataPrefix=${PREFIX}" -o "${TMP}/listrecords.xml"
		curl ${CURL_OPTS} "${BASEURL}?verb=ListIdentifiers&metadataPrefix=${PREFIX}" -o "${TMP}/listidentifiers.xml"
	else
		curl ${CURL_OPTS} "${BASEURL}?verb=ListSets" -o "${TMP}/listsets.xml"
		curl ${CURL_OPTS} "${BASEURL}?verb=ListRecords&metadataPrefix=${PREFIX}&set=${SET}" -o "${TMP}/listrecords.xml"
		curl ${CURL_OPTS} "${BASEURL}?verb=ListIdentifiers&metadataPrefix=${PREFIX}&set=${SET}" -o "${TMP}/listidentifiers.xml"
	fi

	echo
	echo "# Validating the XML:"
	echo "# fails without report are ignored strict wildcard errors"
	if [ ! -f /tmp/OAI-PMH.xsd ]; then
		curl ${CURL_OPTS} --silent "http://www.openarchives.org/OAI/2.0/OAI-PMH.xsd" -o /tmp/OAI-PMH.xsd
	fi

	# solve strict error message with:
	# http://blog.gmane.org/gmane.comp.gnome.lib.xml.general/month=20091101/page=2
	for xml in identify listmetadataformats listsets listrecords listidentifiers; do
		if [ -s ${TMP}/${xml}.xml ]; then
			xmllint --noout --schema ${TMP}/OAI-PMH.xsd ${TMP}/${xml}.xml 2>&1| grep -v strict
		fi
	done

	# cleaning
	for xml in identify listmetadataformats listsets listrecords listidentifiers; do
		rm -f ${TMP}/${xml}.xml
	done
}
