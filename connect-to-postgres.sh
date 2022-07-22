#!/bin/bash
# This script aids the user in connecting to the postgres database
# as the admin user.
#
# The script is dependent on the artifact created during
# the provisioning process.
# That is, `./${resource_group}.env` contains all the necessary information
# to make this script function. It could be implemented differently,
# but this is the easiest way to get the info without asking for it all over again.
# The provisioning user should have committed a file
# named something like: `./codex-resources.env`.
# This file should be given to this script as `--dotenv-file ./codex-resources.env`
#

set -e


###
# Main logic
###

# FIXME duplicate function definition, see also create.sh. move to _lib.sh
function print_help() {
  cat <<EOF
Usage: ${0} ARGS
Arguments:
  -h | --help - This usage information.
  -e | --dotenv-file - File containing environment variable information.
                       This file is the result of the bootstrap provisioning process.
EOF
}

function get_secret() {
  local secret_name=$1
  local key=$2
  local namespace=${3-default}

  echo $(kubectl --namespace $namespace get secret $secret_name -o jsonpath="{.data.$key}" | base64 --decode)
}

function main() {
  echo "Looking up database connection information"
  local db_admin_conn_str=$(get_secret "postgres-creds" "conn_str" "default")
  # FIXME hardcoded version
  local pg_version="13"

  echo "Starting a postgres container to establish a connection"
  kubectl run pg-connection \
    --rm \
    -it \
    --env=conn_str="$db_admin_conn_str" \
    --image "postgres:$pg_version" \
    -- sh -c 'psql "$conn_str"'
  # ^ this will drop the user into a psql shell prompt.
}



###
# Self discovery
###

# MacOS does not support readlink, but it does have perl
KERNEL_NAME=$(uname -s)
if [ "${KERNEL_NAME}" = "Darwin" ]; then
  SCRIPT_PATH=$(perl -e 'use Cwd "abs_path";use File::Basename;print dirname(abs_path(shift))' "$0")
else
  SCRIPT_PATH=$(dirname "$(readlink -f "$0")")
fi

source "${SCRIPT_PATH}/_lib.sh"

# Ensure we have the tools required to run this script
validate_tools az kubectl jq

dot_env_file=''

# Find the resource-group name or the env file
for arg in $@
do
  case $arg in
    -h|--help)
      print_help
      exit 0
    ;;
    -e|--dotenv-file)
      dot_env_file="$2"
      shift 2
    ;;
  esac
done

if [ -z "${dot_env_file}" ]; then
  echo "You must specify the --dotenv-file option"
  exit 1
elif [ ! -f $dot_env_file ]; then
  echo "The given --dotenv-file ${dotenv_file} does not exist"
  exit 1
fi

# Source the configuration from the given dotenv file
source $dot_env_file



###
# Global variable definition
###

resource_group=${RESOURCE_GROUP}
cluster_name=${CLUSTER_NAME}
pg_name=${PG_NAME}



###
# Script runtime operations
###
main "$@"
