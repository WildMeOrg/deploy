#!/bin/bash
# This script creates instances of codex in a cluster.
#
# The script is dependent on the artifact created during the provisioning process.
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

function print_help() {
  cat <<EOF
Usage: ${0} ARGS
Arguments:
  -h | --help - This usage information.
  -e | --dotenv-file - File containing environment variable information.
                       This file is the result of the bootstrap provisioning process.
  --name - Name of the instance. This name should be unique in the cluster
  --edm-admin-email - admin email used for EDM (default: ${edm_admin_email})
  --gitlab-host - FQDN where the gitlab instance lives
  --gitlab-pat - GitLab Personal Access Token (PAT)
  --gitlab-ssh-key-file - File containing the SSH key used to authenticate with GitLab.
                          This assumes the public key is also available
                          with a .pub file extension
  --gitlab-email - GitLab email address of the user
  --gitlab-namespace - GitLab namespace where inside GitLab the assets projects will be stored
  --acm-url - The URL of the ACM instance
  --serving-domain - The domain for which the codex instance will be served
  --edm-disk-size - EDM data volume disk size in gigabytes (default: ${edm_disk_size})
  --houston-disk-size - Houston data volume disk size in gigabytes (default: ${houston_disk_size})
  --sentry-dsn - Sentry DSN address

Example:
  ${0} -e codex-resources.env \
    --name seals-staging \
    --gitlab-host gitlab.sub.wildme.io \
    --gitlab-pat abc123 \
    --gitlab-ssh-key-file seals-staging_gitlab_ssh \
    --gitlab-email dev+seals-staging@wildme.org \
    --gitlab-namespace seals-staging \
    --acm-url https://seals.hydra.dyn.wildme.io/ \
    --serving-domain seals-staging.wildme.org \
    --houston-disk-size 100 \
    --sentry-dsn https://abc123@sentry.dyn.wildme.io/#

EOF
}

function get_secret() {
  local secret_name=$1
  local key=$2
  local namespace=${3-default}

  echo $(kubectl --namespace $namespace get secret $secret_name -o jsonpath="{.data.$key}" | base64 --decode)
}

function random_str() {
  local length=${1-"16"}
  echo "$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1)"
}

# Used to request the user confirm the configure
function confirm_configuration() {
  echo -e "Name:  $1\nEDM Admin Email:  $2\nGitLab Domain:  $3\nGitLab Email:  $8\nGitLab Namespace:  $9\nGitLab PAT:  $4\nGitLab SSH Key Location:  $5\nGitLab Public SSH Key Location:  $5.pub\nACM URL:  $6\nServing Domain:  $7"
  echo ""
  read -p "Do all this look correct? [Y/n] " reply
  case $reply in
    n|N)
      echo "Please correct the configuration and run again"
      exit 1
    ;;
    y|Y|'')
      echo "Confirmed"
    ;;
    *)
      echo "Incorrect response, aborting"
      exit 1
    ;;
  esac
}

function main() {
  local name=$name
  if [ -z "${name}" ]; then
    echo "You must specify a name that is not currently in use"
    exit 1
  fi
  # Sanatize the name of special chars (e.g. dash, underscore)
  local _sanatized_name="$(echo ${name} | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 2 | head -n 1)"
  local edm_admin_email=$edm_admin_email
  local edm_admin_password=$(random_str 64)
  local houston_db_name="${_sanatized_name}_houston"
  local houston_db_username="${_sanatized_name}_houston"
  local edm_db_name="${_sanatized_name}_edm"
  local edm_db_username="${_sanatized_name}_edm"
  local serving_domain=$serving_domain
  local edm_db_password=$(random_str 64)
  local houston_db_password=$(random_str 64)
  local houston_secret_key=$(random_str 32)
  local gitlab_fqdn=$gitlab_fqdn
  local gitlab_pat=$gitlab_pat
  local gitlab_ssh_key=$gitlab_ssh_key_file
  local gitlab_email=$gitlab_email
  local gitlab_namespace=$gitlab_namespace
  local acm_url=$acm_url
  local sentry_dsn=$sentry_dsn

  local namespace=$name
  local edm_disk_size=$edm_disk_size
  local houston_disk_size=$houston_disk_size

  # Obtain the key for the 'wildmepublic' storage account.
  local wildmepublic_storage_key=$(az storage account keys list --resource-group WildMe_Public_Data --account-name wildmepublic --query "[0].value" -o tsv)

  # FIXME Not the best way to accomplish confirming the settings, but it's the quickest.
  confirm_configuration "${name}" "${edm_admin_email}" "${gitlab_fqdn}" "${gitlab_pat}" "${gitlab_ssh_key_file}" "${acm_url}" "${serving_domain}" "${gitlab_email}" "${gitlab_namespace}"

  # Set kubectl context to the current cluster
  kubectl config use-context $cluster_name

  echo "Looking up database connection information"
  local db_fqdn=$(get_secret "postgres-creds" "fqdn" "default")
  local db_admin_user=$(get_secret "postgres-creds" "user" "default")
  local db_admin_password=$(get_secret "postgres-creds" "pass" "default")
  local db_admin_conn_str=$(get_secret "postgres-creds" "conn_str" "default")
  echo "Looking up cache connection information"
  local redis_fqdn=$(get_secret "redis-creds" "fqdn" "default")
  local redis_password=$(get_secret "redis-creds" "primary_key" "default")


  echo "Create namespace $namespace in cluster $cluster_name"
  kubectl create namespace $namespace

  echo "Set current kubectl context to default to namespace $namespace"
  # This enable us to utilize kubectl without specifying the namespace each time.
  kubectl config set-context --current --namespace $namespace

  echo "Create configmap 'codex-configmap' with configuration data"
  kubectl create configmap codex-configmap \
    --from-literal=db_fqdn=$db_fqdn \
    --from-literal=db_admin_user=$db_admin_user \
    --from-literal=gitlab_fqdn=$gitlab_fqdn \
    --from-literal=gitlab_email=$gitlab_email \
    --from-literal=gitlab_namespace=$gitlab_namespace \
    --from-literal=houston_db_name=$houston_db_name \
    --from-literal=houston_db_username=$houston_db_username \
    --from-literal=edm_db_name=$edm_db_name \
    --from-literal=edm_db_username=$edm_db_username \
    --from-literal=acm_url=$acm_url \
    --from-literal=serving_domain=$serving_domain \
    --from-literal=sentry_dsn=''

  echo "Create secret 'codex-secret' with sensative configuration data"
  kubectl create secret generic codex-secret \
    --from-literal=secret-description='Contains sensitive settings used across several processes in the codex applications' \
    --from-literal=db_admin_password=$db_admin_password \
    --from-literal=db_admin_conn_str=$db_admin_conn_str \
    --from-literal=edm_db_password=$edm_db_password \
    --from-literal=edm_admin_email=$edm_admin_email \
    --from-literal=edm_admin_password=$edm_admin_password \
    --from-literal=houston_db_password=$houston_db_password \
    --from-literal=houston_secret_key=$houston_secret_key \
    --from-literal=gitlab_pat=$gitlab_pat
  echo "Create secret 'houston-oauth-secret'"
  kubectl create secret generic houston-oauth-secret \
    --from-literal=secret-description='Contains oauth creds for connecting with Sage' \
    --from-literal=id=$(python -c 'from uuid import uuid4; print(str(uuid4()), end="")') \
    --from-literal=secret="$(random_str 64)"
  echo "Create secret 'redis-connection-secret'"
  kubectl create secret generic redis-connection-secret \
    --from-literal=secret-description='Contains redis connection info' \
    --from-literal=fqdn=$redis_fqdn \
    --from-literal=password=$redis_password
  echo "Create secret 'gitlab-ssh-keypair'"
  kubectl create secret generic gitlab-ssh-keypair \
    --from-literal=secret-description='Contains the gitlab ssh key for use with git via ssh' \
    --from-file=key=$gitlab_ssh_key \
    --from-file=pub=$gitlab_ssh_key.pub
  echo "Create secret 'wildmepublic-storage-creds'"
  kubectl create secret generic wildmepublic-storage-creds \
    --from-literal=secret-description='Contains storage keys for the wildmepublic storage account' \
    --from-literal=azurestorageaccountname=wildmepublic \
    --from-literal=azurestorageaccountkey=$wildmepublic_storage_key

  echo "Create the certificate for ${serving_domain}"
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: codex-tls
spec:
  secretName: codex-tls
  duration: 2160h # 90d
  renewBefore: 360h # 15d
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - ${serving_domain}
EOF

  echo "Create codex initialization jobs"
  kubectl apply -f codex-init.yaml

  echo "Deploy elasticsearch"
  helm repo add elastic https://helm.elastic.co
  helm repo update elastic
  helm upgrade \
    --install \
    elasticsearch elastic/elasticsearch \
    --set replicas=1 \
    --set minimumMasterNodes=1

  echo "Create persistent volume claims for EDM"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: edm-data-pvc
  labels:
    app: edm
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: managed-csi
  resources:
    requests:
      storage: ${edm_disk_size}Gi
EOF

  echo "Create persistent volume claims for Houston"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: houston-data-pvc
  labels:
    app: edm
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: managed-csi
  resources:
    requests:
      storage: ${houston_disk_size}Gi
EOF

  echo "Deploy EDM"
  kubectl apply -f edm-deployment.yaml

  echo "Deploy Codex Frontend"
  kubectl apply -f codex-frontend-deployment.yaml
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: codex-frontend
  annotations:
    # use the shared ingress-nginx
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "6000"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "6000"
spec:
  defaultBackend:
    service:
      name: frontend
      port:
        number: 80
  rules:
  - host: ${serving_domain}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
  tls:
    - secretName: codex-tls
      hosts:
        - ${serving_domain}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: codex-backend
  annotations:
    # use the shared ingress-nginx
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "6000"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "6000"
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  defaultBackend:
    service:
      name: frontend
      port:
        number: 80
  rules:
  - host: ${serving_domain}
    http:
      paths:
      - path: /(houston|api|swaggerui|logout)
        pathType: Prefix
        backend:
          service:
            name: houston-api
            port:
              number: 5000
  tls:
    - secretName: codex-tls
      hosts:
        - ${serving_domain}
EOF

  echo "Deploy Houston"
  kubectl apply -f houston-deployment.yaml
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
# The disk sizes are specified in gigabytes (e.g. 5G)
edm_disk_size=5
houston_disk_size=2048
# Define the default EDM admin email
edm_admin_email="admin@example.com"

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
    --name)
      name="$2"
      shift 2
    ;;
    --edm-admin-email)
      edm_admin_email="$2"
      shift 2
    ;;
    --gitlab-host)
      gitlab_fqdn="$2"
      shift 2
    ;;
    --gitlab-pat)
      gitlab_pat="$2"
      shift 2
    ;;
    --gitlab-ssh-key-file)
      gitlab_ssh_key_file="$2"
      if [ ! -f "${gitlab_ssh_key_file}.pub" ]; then
        echo "The public SSH key file is missing; expected at ${gitlab_ssh_key_file}.pub"
        exit 1
      fi
      shift 2
    ;;
    --gitlab-email)
      gitlab_email="$2"
      shift 2
    ;;
    --gitlab-namespace)
      gitlab_namespace="$2"
      shift 2
    ;;
    --acm-url)
      acm_url="$2"
      shift 2
    ;;
    --serving-domain)
      serving_domain="$2"
      shift 2
    ;;
    --edm-disk-size)
      edm_disk_size="$2"
      shift 2
    ;;
    --houston-disk-size)
      houston_disk_size="$2"
      shift 2
    ;;
    --sentry-dsn)
      sentry_dsn="$2"
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
region=${REGION}
cluster_name=${CLUSTER_NAME}
vnet_name=${VNET_NAME}
pg_name=${PG_NAME}
redis_name=${REDIS_NAME}
storage_name=${STORAGE_NAME}
cert_email=${CERT_EMAIL}
azure_dns_name=${AZURE_DNS_NAME}



###
# Script runtime operations
###
main "$@"
