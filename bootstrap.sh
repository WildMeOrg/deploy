#!/bin/bash
# This script provisions Azure resources that effectively bootstraps an environment
# where instances of codex can be deployed.
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
validate_tools az kubectl helm jq dotenv

###
# Global variable definition
###


# Set default values
_default_resource_group=codex-resources
_default_region=westus2
_default_cluster_name=codex-cluster
_default_node_count=1
_default_node_vm_size=Standard_D4s_v3
_default_public_ip_name=codex-ip
_default_vnet_name=codex-vnet
_default_pg_name=codex-db
# Note, the redis name must be globally unique
_default_redis_name=codex-cache-$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | fold -w 2 | head -n 1)
# Note, the storage name can only contain alphanumeric characters and must be globally unique
_default_storage_name=$(echo $_default_resource_group | LC_ALL=C tr -dc 'a-z0-9')$(cat /dev/urandom | LC_ALL=C tr -dc '0-9' | fold -w 1 | head -n 1)$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | fold -w 3 | head -n 1)
_default_cert_email=dev@wildme.org
_default_azure_dns_name="${_default_resource_group}-$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | fold -w 2 | head -n 1)"

resource_group=${RESOURCE_GROUP-$_default_resource_group}
region=${REGION-$_default_region}
cluster_version=${CLUSTER_VERSION-''}
cluster_name=${CLUSTER_NAME-$_default_cluster_name}
node_count=${NODE_COUNT-$_default_node_count}
node_vm_size=${NODE_VM_SIZE-$_default_node_vm_size}
public_ip_name=${PUBLIC_IP_NAME-$_default_public_ip_name}
vnet_name=${VNET_NAME-$_default_vnet_name}
pg_name=${PG_NAME-$_default_pg_name}
redis_name=${REDIS_NAME-$_default_redis_name}
storage_name=${STORAGE_NAME-$_default_storage_name}
KUBECONFIG=${KUBECONFIG-'~/.kube/config'}
cert_email=${CERT_EMAIL-$_default_cert_email}
azure_dns_name=${AZURE_DNS_NAME-$_default_azure_dns_name}
dot_env_file=${DOTENV_FILE-"./${resource_group}.env"}

# This value is used to enable the listed extensions in postgres
# See also, https://docs.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-extensions#postgres-13-extensions
POSTGRESQL_REQUIRED_EXTENSIONS="uuid-ossp"

###
# Main logic
###

function print_help(){
  cat <<EOF
Usage: ${0} [ARGS] provision|install-credentials|bootstrap
Commands:
  provision: Creates the cluster in Azure, which will will serve codex(s)
  bootstrap: Initializes the cluster's required set of shared tools for serving codex
  install-credentials: Configures the cluster credentials for kubectl usage
Common Arguments:
  -h | --help - This usage information.
  -g | --resource-group  - Name of the resource group to use. Defaults to ${_default_resource_group}
  -n | --cluster-name - Name of the cluster to use. Defaults to ${_default_cluster_name}
  -r | --region - Region to install the cluster in. Defaults to ${_default_region}
  -p | --public-ip-name - Name of the public IP to create. Defaults to gitlab-ext-ip
Provision Specific Arguments:
  -c | --node-count - Number of nodes to use. Defaults to ${_default_node_count}
  -s | --node-vm-size - Type of nodes to use. Defaults to ${_default_node_vm_size}
  --storage-name - Name of the Storage Account to create. Defaults to ${_default_storage_name}
  --postgres-name - Name of the Postgres Flexible Server. Defaults to ${_default_pg_name}
  --redis-name - Name of the Redis server. Defaults to ${_default_redis_name}
Bootstap Specific Arguments:
  --azure-dns-name - Name used in the <name>.<region>.cloudapp.azure.com. Defaults to ${_default_azure_dns_name}
  --cert-email - Email address associated with Lets Encrypt certificate creation. Defaults to ${_default_cert_email}
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

# Provision Azure with the required resources.
function provision_azure(){
  local resource_group=$1
  local region=$2
  local cluster_version=$3
  local cluster_name=$4
  local node_count=$5
  local node_vm_size=$6
  local public_ip_name=$7
  local vnet_name=$8
  local pg_name=$9
  local redis_name=${10}
  local storage_name=${11}

  local pg_version="13"
  local kubernetes_version=""
  local vnet_options=""

  echo "Checking storage name $storage_name is valid"

  az storage account check-name --name $storage_name

  echo "Creating Resource Group: $resource_group"

  az group create \
    --name $resource_group \
    --location $region

  echo "Creating Virtual Network: $vnet_name"
  # Note, DO NOT create a subnet for `10.1.0.0/24`. Kubernetes uses this subnet for internal routing between pods. It's better to simply not use that subnet than to try to work around it.

  az network vnet create \
      --resource-group $resource_group \
      --name $vnet_name \
      --address-prefixes 10.1.0.0/16
  # Create the various subnets within the network.
  # These will be allocated amongst the services later in this function.
  az network vnet subnet create \
      --resource-group $resource_group \
      --vnet-name $vnet_name \
      --name "aks-subnet" \
      --address-prefixes 10.1.1.0/24
  az network vnet subnet create \
      --resource-group $resource_group \
      --vnet-name $vnet_name \
      --name "storage-subnet" \
      --disable-private-endpoint-network-policies \
      --address-prefixes 10.1.2.0/24
  az network vnet subnet create \
      --resource-group $resource_group \
      --vnet-name $vnet_name \
      --name "database-subnet" \
      --disable-private-endpoint-network-policies \
      --address-prefixes 10.1.3.0/24
  az network vnet subnet create \
      --resource-group $resource_group \
      --vnet-name $vnet_name \
      --name "cache-subnet" \
      --disable-private-endpoint-network-policies \
      --address-prefixes 10.1.4.0/24

  echo "Creating $cluster_name cluster in resource group $resource_group"

  if [ -n "$cluster_version" ]; then
    kubernetes_version="--kubernetes-version $cluster_version"
  fi

  local subnet_id=$(az network vnet subnet show --resource-group $resource_group --vnet-name $vnet_name --name "aks-subnet" --query id -o tsv)
  vnet_options="--network-plugin azure --service-cidr 10.0.0.0/16 --dns-service-ip 10.0.0.10 --docker-bridge-address 172.17.0.1/16 --vnet-subnet-id $subnet_id --enable-managed-identity --yes"
  # `--yes` is included because otherwise az will prompt about managed identities

  # AKS creates it's own resource group,
  # which we will need to know about in order to put resource within the clusters reach.
  local node_resource_group=$(az aks create \
    --resource-group $resource_group \
    --name $cluster_name \
    --node-count $node_count \
    --node-vm-size $node_vm_size \
    $kubernetes_version $vnet_options --generate-ssh-keys | \
    jq -r '.nodeResourceGroup')
  install_kubectl_credentials "$resource_group" "$cluster_name" "$KUBECONFIG"

  ##local node_resource_group=$(az aks show -g $resource_group -n $cluster_name --query 'nodeResourceGroup' -o tsv)

  echo "Creating a public IP called $public_ip_name in resource group $node_resource_group"

  # Note, the public-ip must be in the cluster's resource group
  az network public-ip create \
    --resource-group $node_resource_group \
    --name $public_ip_name \
    --sku Standard \
    --allocation-method static

  echo "Creating the Postgres Flexible Server called $pg_name in resource group $resource_group"

  local pg_user="captain"
  local pg_pass="$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)"
  local private_pg_fqdn="${pg_name}.private$(az cloud show | jq -r '.suffixes.postgresqlServerEndpoint')"

  # Create the private DNS zone for the Postgres service domain name.
  local pg_private_dns_zone=$(
    az network private-dns zone show \
      --resource-group $resource_group \
      --name $private_pg_fqdn \
    | jq -r '.id' \
  )
  if [ -z $pg_private_dns_zone ]; then
    # The dns zone doesn't exist, create it.
    local pg_private_dns_zone=$(
      az network private-dns zone create \
        --resource-group $resource_group \
        --name $private_pg_fqdn \
      | jq -r '.id' \
    )
  fi
  # Create the Postgres service
  az postgres flexible-server create \
    --resource-group $resource_group \
    --location $region \
    --name $pg_name \
    --vnet $vnet_name \
    --subnet database-subnet \
    --private-dns-zone $pg_private_dns_zone \
    --admin-user $pg_user \
    --admin-password $pg_pass \
    --version $pg_version \
    --sku-name Standard_D2s_v3
  local pg_fqdn=$(
    az postgres flexible-server show \
      --resource-group $resource_group \
      --name $pg_name \
      --query "fullyQualifiedDomainName" \
      --output tsv \
  )
  local conn_str="$(az postgres flexible-server show-connection-string --server $pg_name --database-name postgres --admin-user $pg_user --admin-password $pg_pass --query 'connectionStrings.psql_cmd' --output tsv)"

  echo "Storing the Postgres credentials and connection info in the cluster ($cluster_name) under the 'default' namespace"

  # Store the credentials for later retrieval and usage.
  kubectl --namespace "default" create secret generic "postgres-creds" \
    --from-literal=user=$pg_user \
    --from-literal=pass=$pg_pass \
    --from-literal=fqdn=$pg_fqdn \
    --from-literal=conn_str="$conn_str"

  echo "Enable necessary postgres extensions"
  az postgres flexible-server parameter set \
    --resource-group $resource_group \
    --server-name $pg_name \
    --name azure.extensions \
    --value $POSTGRESQL_REQUIRED_EXTENSIONS

  echo "Checking connectivity from the cluster to postgres"
  # Verify connection to postgres from the cluster.
  kubectl run check-pg-connection \
    --rm \
    -it \
    --env=conn_str="$conn_str" \
    --image "postgres:$pg_version" \
    -- sh -c 'psql "$conn_str" -c "\l"'

  echo "Creating the Redis server called $redis_name in resource group $resource_group"

  az redis create \
    --resource-group $resource_group \
    --location $region \
    --name $redis_name \
    --minimum-tls-version 1.2 \
    --sku Standard \
    --vm-size C0
  # Create the Private Endpoint:
  az network private-endpoint create \
    --resource-group $resource_group \
    --name "cache-private-endpoint" \
    --location $region \
    --vnet-name $vnet_name \
    --subnet "cache-subnet" \
    --group-id "redisCache" \
    --private-connection-resource-id $(
      az redis show \
         --resource-group $resource_group \
         --name $redis_name \
         | jq -r '.id' \
      ) \
    --connection-name "cache-connection"
  # Create the Private DNS for the virtual network and link it to the virtual network:
  local redis_dns_zone_name="privatelink.redis.cache.windows.net"
  az network private-dns zone create \
    --resource-group $resource_group \
    --name $redis_dns_zone_name
  # Link the private DNS to our vnet:
  az network private-dns link vnet create \
    --resource-group $resource_group \
    --zone-name $redis_dns_zone_name \
    --name "cache-dns-link" \
    --virtual-network $vnet_name \
    --registration-enabled false
  # Create a DNS record to put to the Private Endpoint created to connect to the Storage Account:
  local private_endpoint_nic_id=$(
    az network private-endpoint show \
      --resource-group $resource_group \
      --name "cache-private-endpoint" \
    | jq -r '.networkInterfaces[0].id' \
  )
  local private_endpoint_ip=$(
    az network nic show \
      --ids $private_endpoint_nic_id \
    | jq -r '.ipConfigurations[0].privateIpAddress' \
  )
  az network private-dns record-set a create \
    --resource-group $resource_group \
    --zone-name $redis_dns_zone_name \
    --name $redis_name \
    --output none
  az network private-dns record-set a add-record \
    --resource-group $resource_group \
    --zone-name $redis_dns_zone_name \
    --record-set-name $redis_name \
    --ipv4-address $private_endpoint_ip \
    --output none

  echo "Storing the Redis credentials and connection info in the cluster ($cluster_name) under the 'default' namespace"
  local redis_fqdn=$(az redis show --name $redis_name --resource-group $resource_group | jq -r '.hostName')
  local redis_primary_key=$(az redis list-keys --name $redis_name --resource-group $resource_group | jq -r '.primaryKey')
  # Store the credentials for later retrieval and usage.
  kubectl --namespace "default" create secret generic "redis-creds" \
    --from-literal=primary_key=$redis_primary_key \
    --from-literal=fqdn=$redis_fqdn

  echo "Checking connectivity from the cluster to redis"
  kubectl run check-redis-connection \
    --rm \
    -it \
    --env=fqdn=$redis_fqdn \
    --env=secret=$redis_primary_key \
    --env=script='import os, redis; host=os.getenv("fqdn"); key=os.getenv("secret"); r=redis.from_url(f"rediss://:{key}@{host}:6380/0"); r.set("foo", "bar"); assert r.get("foo") == b"bar", r.get("foo"); r.delete("foo"); print("passed")' \
    --image python:3.10 \
    -- \
    sh -c 'python -m pip install redis; python -c "$script"'

  echo "Creating the Storage Account called $storage_name in resource group $node_resource_group"
  az storage account create \
    --name $storage_name \
    --resource-group $node_resource_group \
    --location $region \
    --sku Standard_LRS \
    --kind StorageV2
  # Create the Private Endpoint:
  local storage_id=$(az storage account show --resource-group $node_resource_group --name $storage_name | jq -r '.id')
  az network private-endpoint create \
    --resource-group $resource_group \
    --name "${storage_name}-storage-private-endpoint" \
    --location $region \
    --vnet-name $vnet_name \
    --subnet storage-subnet \
    --group-id "file" \
    --private-connection-resource-id $storage_id \
    --connection-name "${resource_group}-storage-connection"
  # Create the Private DNS for the virtual network and link it to the virtual network:
  local storage_dns_zone_name="privatelink.file.$(az cloud show | jq -r '.suffixes.storageEndpoint')"
  az network private-dns zone create \
    --resource-group $resource_group \
    --name $storage_dns_zone_name
  # Link the private DNS to our vnet:
  az network private-dns link vnet create \
    --resource-group $resource_group \
    --zone-name $storage_dns_zone_name \
    --name "${resource_group}-file-storage-dns-link" \
    --virtual-network $vnet_name \
    --registration-enabled false
  # Create a DNS record to put to the Private Endpoint created to connect to the Storage Account:
  local private_endpoint_nic_id=$(
    az network private-endpoint show \
      --resource-group $resource_group \
      --name "${storage_name}-storage-private-endpoint" \
    | jq -r '.networkInterfaces[0].id' \
  )
  local private_endpoint_ip=$(
    az network nic show \
      --ids $private_endpoint_nic_id \
    | jq -r '.ipConfigurations[0].privateIpAddress' \
  )
  az network private-dns record-set a create \
    --resource-group $resource_group \
    --zone-name $storage_dns_zone_name \
    --name $storage_name \
    --output none
  az network private-dns record-set a add-record \
    --resource-group $resource_group \
    --zone-name $storage_dns_zone_name \
    --record-set-name $storage_name \
    --ipv4-address $private_endpoint_ip \
    --output none

  echo "Storing the Storage Account credentials and connection info in the cluster ($cluster_name) under the 'default' namespace"
  local storage_fqdn=$(az storage account show --resource-group $node_resource_group --name $storage_name | jq -r '.primaryEndpoints.file')
  local storage_primary_key=$(az storage account keys list --resource-group $node_resource_group --account-name $storage_name --query "[0].value" -o tsv)
  local storage_conn_str=$(az storage account show-connection-string -n $storage_name -g $node_resource_group -o tsv)
  # Store the credentials for later retrieval and usage.
  kubectl --namespace "default" create secret generic "file-storage-creds" \
    --from-literal=primary_key=$storage_primary_key \
    --from-literal=fqdn=$storage_fqdn \
    --from-literal=conn_str=$storage_conn_str$
  # This can be used directly in yaml volume mounts against file shares
  kubectl create secret generic "azure-file-storage-volume-secret" \
    --from-literal=azurestorageaccountname=$storage_name \
    --from-literal=azurestorageaccountkey=$storage_primary_key

  echo "Checking connectivity from the cluster to file storage"
  kubectl run check-storage-connection \
    --rm \
    -it \
    --env=httpEndpoint=$storage_fqdn \
    --image busybox:latest \
    -- \
    sh -c 'nc -zvw3 $(echo $httpEndpoint | cut -c7-$(expr length $httpEndpoint) | tr -d "/") 445'

  write_to_dotenv "RESOURCE_GROUP" "$resource_group"
  write_to_dotenv "REGION" "$region"
  write_to_dotenv "CLUSTER_NAME" "$cluster_name"
  write_to_dotenv "NODE_COUNT" "$node_count"
  write_to_dotenv "NODE_VM_SIZE" "$node_vm_size"
  write_to_dotenv "PUBLIC_IP_NAME" "$public_ip_name"
  write_to_dotenv "VNET_NAME" "$vnet_name"
  write_to_dotenv "PG_NAME" "$pg_name"
  write_to_dotenv "REDIS_NAME" "$redis_name"
  write_to_dotenv "STORAGE_NAME" "$storage_name"
}

function write_to_dotenv() {
    local name=$1
    local value=$2
    ##global dotenv_file

    dotenv -f $dotenv_file set $name "$value"
}

function install_kubectl_credentials(){
  local resource_group=$1
  local cluster_name=$2
  local kubectl_config_file=$3

  az aks get-credentials \
    --resource-group $resource_group \
    --name $cluster_name \
    --file $kubectl_config_file
}

function bootstrap_cluster() {
  local resource_group=$1
  local region=$2
  local cluster_name=$3
  local public_ip_name=$4
  local cert_email=$5
  local azure_dns_name=$6

  echo "Installing ingress-nginx as Kubernetes Ingress into cluster $cluster_name"

  local ingress_namespace="ingress-nginx"
  local node_resource_group=$(az aks show -g $resource_group -n $cluster_name --query 'nodeResourceGroup' -o tsv)
  local public_ip=$(az network public-ip show --resource-group $node_resource_group --name $public_ip_name --query "ipAddress" --output tsv)

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update ingress-nginx

  helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
    --install \
    --timeout 600s \
    --version 4.0.15 \
    --create-namespace \
    --namespace $ingress_namespace \
    --set controller.service.loadBalancerIP=$public_ip \
    --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$azure_dns_name

  echo "Installing cert-manager for certificate management into cluster $cluster_name"

  local certmgr_namespace=cert-manager

  helm repo add jetstack https://charts.jetstack.io
  helm repo update jetstack

  helm upgrade cert-manager jetstack/cert-manager \
    --install \
    --version v1.6.1 \
    --create-namespace \
    --namespace $certmgr_namespace \
    --set prometheus.enabled=false \
    --set installCRDs=true

  echo "Creating Lets Encrypt ClusterIssuer for cluster $cluster_name using $cert_email"

  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: $cert_email
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-secret-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

  write_to_dotenv "AZURE_DNS_NAME" "$azure_dns_name"
  write_to_dotenv "CERT_EMAIL" "$cert_email"

  echo "Cluster receiving requests at https://$azure_dns_name.$region.cloudapp.azure.com/"
  echo "(note, no apps are running yet and SSL may take a few minutes to initialize)"
  echo "You may also assign your own DNS records to IP address: $public_ip"
}

function main(){
  case $1 in
    provision)
      provision_azure "$resource_group" "$region" "$cluster_version" "$cluster_name" "$node_count" "$node_vm_size" "$public_ip_name" "$vnet_name" "$pg_name" "$redis_name" "$storage_name"
    ;;
    install-credentials)
      install_kubectl_credentials "$resource_group" "$cluster_name" "$KUBECONFIG"
    ;;
    bootstrap)
      bootstrap_cluster "$resource_group" "$region" "$cluster_name" "$public_ip_name" "$cert_email" "$azure_dns_name"
    ;;
    *)
      echo "Invalid Run Type $1: provision|bootstrap"
      print_help
      exit 1
  esac
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
    -g|--resource-group)
      resource_group="$2"
      shift 2
      # Associate the resource-group name with the .env file
      dotenv_file="./${resource_group}.env"
    ;;
    -r|--region)
      region="$2"
      shift 2
    ;;
    -n|--cluster-name)
      cluster_name="$2"
      shift 2
    ;;
    -c|--node-count)
      node_count="$2"
      shift 2
    ;;
    -s|--node-vm-size)
      node_vm_size="$2"
      shift 2
    ;;
    -p|--public-ip-name)
      public_ip_name="$2"
      shift 2
    ;;
    --postgres-name)
      pg_name="$2"
      shift 2
    ;;
    --redis-name)
      redis_name="$2"
      shift 2
    ;;
    --storage-name)
      storage_name="$2"
      shift 2
    ;;
    --azure-dns-name)
      azure_dns_name="$2"
      shift 2
    ;;
    --cert-email)
      cert_email="$2"
      shift 2
    ;;
    [?])
      echo "Invalid Argument Passed: $arg"
      print_help
      exit 1
    ;;
  esac
done

# Main entrypoint for the script
if ! is_sourced; then
  main "$@"
fi
