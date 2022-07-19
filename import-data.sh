#!/bin/bash

set -eo pipefail

timeout=${TIMEOUT-20}
poll_frequency=${POLL_FREQUENCY-1}
edm_database_file=${EDM_DATABASE_FILE-db-edm.sql}
houston_database_file=${HOUSTON_DATABASE_FILE-db-houston.sql}
migration_tarball=
remote_ssh_key=
remote_host=
remote_path=
remote_login=

function print_help(){
  cat <<EOF
Usage: ${0} ARGS

Required Arguments:
  -e | --dotenv-file    File containing environment variable information.
                        This file is the result of the bootstrap provisioning process.
  --migration-tarball   tarball containing db dumps and asset file mapping
  --remote-ssh-key      ssh key (file) to access remote asset data
  --remote-host         remote host containing asset data
  --remote-path         remote path to asset data directory
  --remote-login        remote user login name

Optional Arguments:

Example:
  ${0} --remote-ssh-key ~/.ssh/id_rsa --remote-login ubuntu --remote-host mammals.wildbook.org --remote-path /data/wildbook_data_dir/ --migration-tarball ./mammals.tgz

Note, about the migration tarball... The contents of the migration tarball should look
exactly like the following:It is a tarball containing three files (without an encapsulating directory:

    $ tar tzf mammals.tgz
    assets.tsv
    edm.sql.gz
    houston.sql.gz

EOF
}


for arg in $@
do
  case $arg in
    -e|--dotenv-file)
      dot_env_file="$2"
      shift 2
    ;;
    --migration-tarball)
      migration_tarball="$2"
      shift
      shift
    ;;
    --remote-ssh-key)
      remote_ssh_key="$2"
      shift
      shift
    ;;
    --remote-host)
      remote_host="$2"
      shift
      shift
    ;;
    --remote-path)
      remote_path="$2"
      shift
      shift
    ;;
    --remote-login)
      remote_login="$2"
      shift
      shift
    ;;
    # --option)
    #   # $2 is the value for the option
    #   site_name="$2"
    #   shift
    #   shift
    #   ;;
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
  echo "The given --dotenv-file ${dot_env_file} does not exist"
  exit 1
fi

# Source the configuration from the given dotenv file
source $dot_env_file


function push_file() {
  local src=$1
  local dst=$2

  az storage file upload \
    --account-name $storage_name \
    --account-key $storage_key \
    --share-name $share_name \
    --path "$dst" \
    --source "$src"
}


function main() {
  if [[ -z "${migration_tarball}" || -z "${remote_ssh_key}" || -z "${remote_host}" || -z "${remote_path}" || -z "${remote_login}" ]]; then
    echo "ERROR: Missing required argument"
    print_help
    exit 1
  fi

  # Create the storage share where the sql dump files will reside
  echo 'Creating the storage share where sql dump files will be temporarily stored'
  az storage share create -n $share_name --connection-string $storage_connection_string > /dev/null
  kubectl delete secret import-data-azure-files-secret || echo -n
  kubectl create secret generic import-data-azure-files-secret \
    --from-literal=azurestorageaccountname=$storage_name \
    --from-literal=azurestorageaccountkey=$storage_key

  # Load the sql dump files into the storage share
  echo 'Uploading the sql dump files to the storage share'
  # FIXME hardcoded backup file name
  local tmp_dir=$(mktemp -d -t import-XXXXXXXXXX)
  tar xzf $migration_tarball -C $tmp_dir
  # Migration tarball file structure:
  #  - ./edm.sql.gz
  #  - ./houston.sql.gz
  #  - ./assets.tsv
  push_file "${tmp_dir}/edm.sql.gz" edm.sql.gz
  push_file "${tmp_dir}/houston.sql.gz" houston.sql.gz
  push_file "${tmp_dir}/assets.tsv" assets.tsv
  rm -rf ${tmp_dir}

  # Create the secret for the remote host
  echo 'Storing secret settings for import use in the a cluster'
  kubectl delete secret codex-import-remote-secret || echo -n
  kubectl create secret generic \
    codex-import-remote-secret \
    --from-file=ssh_key=$remote_ssh_key \
    --from-literal=host=$remote_host \
    --from-literal=path=$remote_path \
    --from-literal=user=$remote_login

  # Delete previously completed jobs of the same name
  echo 'Cleanup any previously completed import jobs'
  kubectl delete jobs.batch -l app=import || echo -n
  kubectl wait --for=delete jobs.batch -l app=import --timeout=4m

  # Scale back EDM and Houston deployments to disconnect from databases
  echo 'Shutdown pods connected to the database'
  kubectl scale --replicas=0 deployment/edm
  kubectl scale --replicas=0 deployment/houston-api
  kubectl scale --replicas=0 deployment/houston-worker
  kubectl scale --replicas=0 deployment/houston-beat

  # Wait for the scale operation to delete all deployed pods
  echo 'Waiting for pods to shutdown'
  kubectl wait --for=delete pod -l app=houston --timeout=4m
  kubectl wait --for=delete pod -l app=edm --timeout=4m

  # Apply the job configuration
  echo 'Start import jobs'
  kubectl apply -f _import-data.yaml

  # Wait for jobs to complete
  echo 'Waiting for jobs to finish (this can take several hours)'
  kubectl wait --for=condition=Complete jobs.batch -l app=import --timeout=4h
  echo 'Import finished'

  # Cleanup
  echo 'Cleaning up'
  kubectl delete configmap codex-import-scripts-configmap
  kubectl delete secret codex-import-remote-secret
  kubectl delete secret import-data-azure-files-secret
  # kubectl delete jobs.batch -l app=import
  kubectl delete pvc codex-import-data-pvc --wait=false

  # Bring up EDM and Houston deployments to the preconfigured scale
  echo 'Bringing pods back online'
  # TODO We should likely scale up the deployment rather than re-applying the deployment.
  kubectl scale --replicas=1 deployment -l app=edm
  kubectl scale --replicas=1 deployment -l app=houston

  exit $?
}


# check to see if this file is being run or sourced from another script
function _is_sourced() {
  # See also https://unix.stackexchange.com/a/215279
  # macos bash source check OR { linux shell check }
  [[ "${#BASH_SOURCE[@]}" -eq 0 ]] || { [ "${#FUNCNAME[@]}" -ge 2 ]  && [ "${FUNCNAME[0]}" = '_is_sourced' ] && [ "${FUNCNAME[1]}" = 'source' ]; }
}


###
# Global variable definition
###
resource_group=${RESOURCE_GROUP}
node_resource_group=${NODE_RESOURCE_GROUP}
region=${REGION}
cluster_name=${CLUSTER_NAME}
storage_name=${STORAGE_NAME}
share_name=import-data

###
# Additional derived variables from globals
###
storage_connection_string=$(az storage account show-connection-string -n $storage_name -g $node_resource_group -o tsv)
storage_key=$(az storage account keys list --resource-group $node_resource_group --account-name $storage_name --query "[0].value" -o tsv)


if ! _is_sourced; then
  main "$@"
fi
