#! /bin/bash

# Invoke using:
#	cleanaws [query] [options]
#
# Where:
# 	[query]		is the query for the tags you want to find
#			(the query can be anywhere in the tag after kubernetes.io/cluster/)
#
# 	--list		will only list the tags and not ask if you want to delete resources
# 	--expand	lists all resources with a tag
# 	--all		list all tags (not just kubernetes.io clusters)
#
# Prerequisites:
#	- Have access to AWS (if you have more than one profile set up, you should
#		manually update the access keys for the account you want to use)
#	- Already have hiveutil installed and updated the HIVEUTIL_PATH for it here
#		See: https://github.com/openshift/hive

REGION_FILTER=${REGION_FILTER:-""}

# Parse arguments
while [[ $# -gt 0 ]]; do
	key="$1"

	case $key in
	--list)
		LIST_TAGS=true
		shift
		;;
	--expand)
		EXPAND_RESOURCES=true
		shift
		;;
	--all)
		LIST_ALL_TAGS=true
		shift
		;;
	--silent)
		SILENT=true
		;;
	*) # default
		QUERY_INPUT=${1}
		shift
		;;
	esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

if [[ ${LIST_ALL_TAGS} != true ]]; then
	QUERY="kubernetes\.io/cluster/.*"
else
	QUERY=".*/.*"
fi
if [[ -n ${QUERY_INPUT} ]]; then
	QUERY+="${QUERY_INPUT}.*"
fi

# if [[ "${LIST_TAGS}" != "true" ]]; then
# 	HIVEUTIL_PATH=${HOME}/workspace/hive/
# 	cd ${HIVEUTIL_PATH}
# 	git checkout origin master &>/dev/null
# 	git fetch --all &>/dev/null
# 	if [[ -n "$(git status | grep "branch is behind")" && $1 != '--list' ]]; then
# 		while read -r -p "hiveutils is out of date. Update hiveutils before continuing (y/n)? " response; do
# 			case "$response" in
# 			y)
# 				echo "Pulling latest Git changes..."
# 				git pull &>/dev/null
# 				echo "Building CLI..."
# 				make build 1>/dev/null
# 				break
# 				;;
# 			n)
# 				break
# 				;;
# 			esac
# 		done
# 	fi
# fi

AWS_REGIONS=$(aws ec2 describe-regions --output text | awk '/'${REGION_FILTER}'/ {print $4}')
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-"$(cat ~/.aws/credentials | awk -F ' = ' '/access_key_id/ {print $2}')"}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-"$(cat ~/.aws/credentials | awk -F ' = ' '/secret_access_key/ {print $2}')"}

ID_FOUND="$(echo "${AWS_ACCESS_KEY_ID}" | wc -l | awk '{print $1}')"
if [[ "${ID_FOUND}" != "1" ]]; then
	echo "Found ${ID_FOUND} access keys but expected 1. Verify your credentials file at ~/.aws/credentials or export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY before running the script."
	exit 1
fi

CLEANUP=()

for region in ${AWS_REGIONS}; do
	echo "===== REGION ${region} ====="
	TAGS=$(aws resourcegroupstaggingapi get-tag-keys --region=${region} --output text | grep -o "${QUERY}")
	if [[ ! -z ${TAGS} ]]; then
		for tag in ${TAGS}; do
			if [[ ${LIST_TAGS} == true ]]; then
				RESOURCES=($(aws resourcegroupstaggingapi get-resources --tag-filters Key=${tag} --region=${region} --output json | jq -r .ResourceTagMappingList[].ResourceARN))
				NUM_RESOURCES=${#RESOURCES[@]}
				if [[ ${NUM_RESOURCES} -gt 1 || ${EXPAND_RESOURCES} == true ]]; then
					echo ${tag}
					if [[ ${NUM_RESOURCES} -gt 1 && ${NUM_RESOURCES} -lt 15 ]]; then
						CLEANUP[${#CLEANUP[@]}]=${tag}
					fi
					if [[ ${EXPAND_RESOURCES} == true ]]; then
						for resource in ${RESOURCES[@]}; do
							echo "    ${resource}"
						done
					fi
				fi
			else
				while read -r -p "Remove resources tagged ${tag} (y/n)? " response; do
					case "$response" in
					y)
						#${HIVEUTIL_PATH}/bin/hiveutil aws-tag-deprovision ${tag}=owned --region ${region} --loglevel debug
						/usr/local/bin/hiveutil aws-tag-deprovision ${tag}=owned --region ${region} --loglevel debug
						break
						;;
					n)
						break
						;;
					esac
				done
			fi
		done
	fi
done

if [[ ${#CLEANUP[@]} > 0 && ${LIST_ALL_TAGS} != true ]]; then
	echo -e "\nThe following tags may need cleanup:"
	for cluster in ${CLEANUP[@]}; do
		echo "    ${cluster}"
	done
fi
