#!/bin/bash

set -eo pipefail

remote_ssh_key=
remote_host=
remote_login=
remote_path=
remote_backup_path=/data/backups/
dot_env_file=''


function print_help(){
  cat <<EOF
Usage: ${0} ARGS

Required Arguments:
  -e | --dotenv-file    File containing environment variable information.
                        This file is the result of the bootstrap provisioning process.
  --remote-ssh-key      ssh key (file) to access remote asset data
  --remote-host         remote host containing houston
  --remote-login        remote user login name
  --remote-path         remote path to houston data directory
  --remote-backup-path  remote path to the backup directory

Optional Arguments:

Example:
  ${0} -e codex-resources.env --remote-ssh-key ~/.ssh/keypairs/zebra_rsa --remote-login ubuntu --remote-host zebra.wildme.org --remote-path /data/dockerd/volumes/houston_houston-var/_data/var/ --remote-backup-path /data/backup

EOF
}


for arg in $@
do
  case $arg in
    -e|--dotenv-file)
      dot_env_file="$2"
      shift 2
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
    --remote-login)
      remote_login="$2"
      shift
      shift
    ;;
    --remote-path)
      remote_path="$2"
      shift
      shift
    ;;
    --remote-backup-path)
      remote_backup_path="$2"
      shift
      shift
    ;;
    # --option)
    #   # $2 is the value for the option
    #   site_name="$2"
    #   shift
    #   shift
    #   ;;
    -h|--help)
      print_help
      exit 0
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
  echo "The given --dotenv-file ${dot_env_file} does not exist"
  exit 1
fi

# Source the configuration from the given dotenv file
source $dot_env_file


function get_ssh_connection_string() {
  echo "${remote_login}@${remote_host}"
}
function get_ssh_connection_args() {
  echo "-i ${remote_ssh_key}"
}
function copy_ssh_file() {
  local src=$1
  local dst=$2

  scp $(get_ssh_connection_args) "$(get_ssh_connection_string):${src}" $dst
}


function push_sql_dump_file() {
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
  if [[ -z "${remote_ssh_key}" || -z "${remote_host}" || -z "${remote_path}" || -z "${remote_login}" ]]; then
    echo "ERROR: Missing required argument"
    print_help
    exit 1
  fi

  # Create the storage share where the sql dump files will reside
  echo 'Creating the storage share where sql dump files will be temporarily stored'
  local share_name=import-data
  az storage share create -n $share_name --connection-string $storage_connection_string > /dev/null
  kubectl delete secret import-data-azure-files-secret || echo -n
  kubectl create secret generic import-data-azure-files-secret \
    --from-literal=azurestorageaccountname=$storage_name \
    --from-literal=azurestorageaccountkey=$storage_key

  # Load the sql dump files into the storage share
  echo 'Uploading the sql dump files to the storage share'
  # FIXME hardcoded backup file name
  local tmp_dir=$(mktemp -d -t replicate-XXXXXXXXXX)
  copy_ssh_file "${remote_backup_path}/postgresql/zebra-codex-db-edm.sql.gz" "${tmp_dir}/edm.sql.gz"
  copy_ssh_file "${remote_backup_path}/postgresql/zebra-codex-db-houston.sql.gz" "${tmp_dir}/houston.sql.gz"
  push_sql_dump_file "${tmp_dir}/edm.sql.gz" edm.sql.gz
  push_sql_dump_file "${tmp_dir}/houston.sql.gz" houston.sql.gz
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
  echo 'Start replication jobs'
  kubectl apply -f _replicate-data-from-backup.yaml

  # Wait for jobs to complete
  echo 'Waiting for jobs to finish (this can take several hours)'
  kubectl wait --for=condition=Complete jobs.batch -l app=import --timeout=4h
  echo 'Import finished'

  # Cleanup
  echo 'Cleaning up'
  kubectl delete configmap codex-import-scripts-configmap
  kubectl delete secret codex-import-remote-secret
  kubectl delete secret import-data-azure-files-secret
  kubectl delete jobs.batch -l app=import
  kubectl delete pvc codex-import-data-pvc --wait=false

  # Bring up EDM and Houston deployments to the preconfigured scale
  echo 'Bringing pods back online'
  # TODO We should likely scale up the deployment rather than re-applying the deployment.
  kubectl apply -f edm-deployment.yaml
  kubectl apply -f houston-deployment.yaml

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

###
# Additional derived variables from globals
###
storage_connection_string=$(az storage account show-connection-string -n $storage_name -g $node_resource_group -o tsv)
storage_key=$(az storage account keys list --resource-group $node_resource_group --account-name $storage_name --query "[0].value" -o tsv)


if ! _is_sourced; then
  main "$@"
fi
