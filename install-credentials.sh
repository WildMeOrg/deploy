#!/bin/bash
# This script installs the Azure Kubernetes Service credentials
# for use with the kubectl and other Kubernetes api tools.
#

set -e

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
validate_tools az


###
# Main logic
###

function print_help(){
  cat <<EOF
Usage: ${0} -e <dotenv-file>
Description:
  Installs the Azure Kubernetes Service (AKS) credentials
  for use with the kubectl utility and other Kubernetes API tools.
Arguments:
  -h | --help - This usage information.
  -e | --dotenv-file - File containing environment variable information. {Defaults to ${_default_dot_env_file}

EOF
}

# This writes the cluster's credentials to the kubectl config file.
function install_kubectl_credentials() {
  local resource_group=$1
  local cluster_name=$2
  local kubectl_config_file=$3

  # Let the Azure CLI write the configuration
  az aks get-credentials \
    --resource-group $resource_group \
    --name $cluster_name \
    --file $kubectl_config_file
}

function main(){
  install_kubectl_credentials ${resource_group} ${cluster_name} '~/.kube/config'
}


###
# Script runtime operations
###

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
    [?])
      echo "Invalid Argument Passed: $arg"
      print_help
      exit 1
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

# read values from sourced dotenv
resource_group=${RESOURCE_GROUP}
cluster_name=${CLUSTER_NAME}

# Main entrypoint for the script
if ! is_sourced; then
  main
fi
