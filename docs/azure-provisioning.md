# Azure provisioning

Three services need to be provisioned for this deployment strategy: AKS, Postgres, and Redis. You'll also need to create a Resource Group for these services to be organized within.

Note, these services are installed during the bootstrap process. This documentation can be useful for fully understanding the relationships, networking and service creation.

## Resource Group creation

Follow the instructions at https://docs.microsoft.com/en-us/azure/aks/kubernetes-walkthrough#create-a-resource-group

Create the resource group:

    export RG_NAME="<your-choosen-name>"
    export RG_LOC="westus2"
    az group create --name $RG_NAME --location $RG_LOC

For a list of regions/locations use `az account list-locations`.
To back out these changes use `az group delete $RG_NAME`.

## Create the Virtual Network

Create the virtual network where all services will reside.

    export VNET_NAME="${RG_NAME}-vnet"

    az network vnet create \
        --resource-group $RG_NAME \
        --name $VNET_NAME \
        --address-prefixes 10.1.0.0/16

Create the various subnets within the network. These will be allocated amongst the services.

    az network vnet subnet create \
        --resource-group $RG_NAME \
        --vnet-name $VNET_NAME \
        --name aks-subnet \
        --address-prefixes 10.1.1.0/24

    az network vnet subnet create \
        --resource-group $RG_NAME \
        --vnet-name $VNET_NAME \
        --name storage-subnet \
        --disable-private-endpoint-network-policies \
        --address-prefixes 10.1.2.0/24

    az network vnet subnet create \
        --resource-group $RG_NAME \
        --vnet-name $VNET_NAME \
        --name database-subnet \
        --disable-private-endpoint-network-policies \
        --address-prefixes 10.1.3.0/24

    az network vnet subnet create \
        --resource-group $RG_NAME \
        --vnet-name $VNET_NAME \
        --name cache-subnet \
        --disable-private-endpoint-network-policies \
        --address-prefixes 10.1.4.0/24

Note, do not create a subnet for `10.1.0.0/24`. Kubernetes uses this subnet for internal routing between pods. It's better to simply not use that subnet than to try to work around it.


## Create the AKS cluster

Ref: https://docs.microsoft.com/en-us/azure/aks/configure-azure-cni#plan-ip-addressing-for-your-cluster
Ref: https://docs.microsoft.com/en-us/azure/aks/kubernetes-walkthrough#create-aks-cluster
Ref: https://docs.microsoft.com/en-us/azure/aks/kubernetes-walkthrough#connect-to-the-cluster

Azure Kubernetes Service (AKS) can contain one or more clusters. One node in the cluster is sufficient for developer use, but more than one node should be used to properly test a production environment.

Create the AKS cluster:

    export CLUSTER_NAME="${RG_NAME}-aks"
    az aks create \
        --resource-group $RG_NAME \
        --name $CLUSTER_NAME \
        --node-count 1 \
        --node-vm-size Standard_D4s_v3 \
        --enable-managed-identity \
        --generate-ssh-keys \
        --network-plugin azure \
        --service-cidr 10.0.0.0/16 \
        --dns-service-ip 10.0.0.10 \
        --docker-bridge-address 172.17.0.1/16 \
        --vnet-subnet-id $(
            az network vnet subnet list \
                --resource-group $RG_NAME \
                --vnet-name $VNET_NAME \
                | jq -r '.[] | select(.name == "aks-subnet") | .id' \
            ) \
        --enable-managed-identity \
        --yes \
        --no-wait

To list available node vm sizes use `az vm list-sizes --location $RG_LOC`. It is important to pick a size you believe will work best for the application in quesition because the size cannot be adjusted without recreating the cluster.

<!-- explaination of sizes at https://docs.microsoft.com/en-us/azure/virtual-machines/sizes -->

Configuring for connecting via `kubectl`:

    az aks get-credentials --resource-group $RG_NAME --name $CLUSTER_NAME

<!-- use `--file "${CLUSTER_NAME}-kubeconfig.yaml"` to isolate the config -->
<!-- and `export KUBECONFIG="${CLUSTER_NAME}-kubeconfig.yaml:$KUBECONFIG"` -->

Verify your connection with `kubectl get nodes`

## Provision the Static IP address

Create the static public ip address.

    az network public-ip create \
        --resource-group $(az aks show -g $RG_NAME -n $CLUSTER_NAME --query 'nodeResourceGroup' -o tsv) \
        --name "$RG_NAME-public-ip" \
        --sku Standard \
        --allocation-method static

<!-- az network public-ip create \ -->
<!--   --resource-group $RG_NAME \ -->
<!--   --name "$RG_NAME-public-ip" \ -->
<!--   --sku Standard \ -->
<!--   --allocation-method static -->

<!--
TODO: Ideally we create the public-ip address in the main `$RG_NAME` resource group. It would provide us with the ability to recreate the AKS cluster without deleting the public-ip.
I'm having difficulty allowing AKS use the resource created in another group. Apparently, there is a way to allow for this, see https://docs.microsoft.com/en-us/azure/aks/static-ip#use-a-static-ip-address-outside-of-the-node-resource-group
For now I'm simply creating the public-ip address inside the AKS created resource group (i.e. the group name starting with `mc_`).
It's difficult to achieve this without diving into managed identities.
-->

This will be used later on in the instructions. For now it is sufficient to create the address.


## Provisioning Postgres

To create the Postgres service, follow the instructions at https://docs.microsoft.com/en-us/azure/postgresql/quickstart-create-server-database-azure-cli#create-an-azure-database-for-postgresql-server

Create a few variables used throughout this section:

    export PG_NAME="${RG_NAME}-db"
    export POSTGRES_USER="captain"
    export POSTGRES_PASSWORD="$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)"
    export PRIVATE_PG_FQDN="${PG_NAME}.private$(az cloud show | jq -r '.suffixes.postgresqlServerEndpoint')"

    export HOUSTON_DATABASE="houston"
    export HOUSTON_USER="houston"
    export HOUSTON_PASSWORD="$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)"
    # save these settings for later 'houston_db_name'     $HOUSTON_DATABASE
    # save these settings for later 'houston_db_username' $HOUSTON_USER
    # save these settings for later 'houston_db_password' $HOUSTON_PASSWORD

    export EDM_DATABASE="edm"
    export EDM_USER="edm"
    export EDM_PASSWORD="$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)"
    # save these settings for later 'edm_db_name'     $EDM_DATABASE
    # save these settings for later 'edm_db_username' $EDM_USER
    # save these settings for later 'edm_db_password' $EDM_PASSWORD

Create the private DNS zone for the Postgres service domain name.

    az network private-dns zone create \
        --resource-group $RG_NAME \
        --name $PRIVATE_PG_FQDN

Create the Postgres service:

    az postgres flexible-server create \
        --resource-group $RG_NAME \
        --location $RG_LOC \
        --name $PG_NAME \
        --vnet $VNET_NAME \
        --subnet database-subnet \
        --private-dns-zone $(
            az network private-dns zone show \
                --resource-group $RG_NAME \
                --name $PRIVATE_PG_FQDN \
                | jq -r '.id' \
            ) \
        --admin-user $POSTGRES_USER \
        --admin-password $POSTGRES_PASSWORD \
        --version 13 \
        --sku-name Standard_D2s_v3


Use `az postgres flexible-server list-skus --location $GITLAB_RG_LOC` to see available tiers.
In this case we're using `Standard_D2s_v3`, which should be enough for developer use.

Update the configuration setting `db_host` value in `codex-configmap.yaml` using:

    export PG_FQDN=$(
        az postgres flexible-server show \
            --resource-group $RG_NAME \
            --name $PG_NAME \
            --query "fullyQualifiedDomainName" \
            --output tsv \
        )
    # save these settings for later 'db_fqdn'           $PG_FQDN
    # save these settings for later 'db_host'           $PG_NAME
    # save these settings for later 'db_admin_user'     $POSTGRES_USER
    # save these settings for later 'db_admin_password' $POSTGRES_PASSWORD
    # save these settings for later 'db_admin_conn_str' "$(az postgres flexible-server show-connection-string --server $PG_NAME --database-name postgres --admin-user $POSTGRES_USER --admin-password $POSTGRES_PASSWORD --query 'connectionStrings.psql_cmd' --output tsv)"

And if you are installing ACM as part of this deployment:

    kubectl create secret generic acm-secret --from-literal=db_password=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)

To get the connection string to the server and test the connection:

    kubectl run connection-check \
        --rm \
        -it \
        --env=conn_str="$(az postgres flexible-server show-connection-string --server $PG_NAME --database-name postgres --admin-user $POSTGRES_USER --admin-password $POSTGRES_PASSWORD --query 'connectionStrings.psql_cmd' --output tsv)" \
        --image postgres:13 \
        -- sh -c 'psql "$conn_str" -c "\l"'

This `kubectl run` command starts a pod in the cluster to check for connectivity. It should output a list of databases.

<!-- TODO: Data migration... See https://docs.microsoft.com/en-us/azure/dms/tutorial-postgresql-azure-postgresql-online -->


## Provisioning Redis

Ref: https://docs.microsoft.com/en-us/azure/azure-cache-for-redis/scripts/create-cache

To create the Redis service:

    export REDIS_NAME="${RG_NAME}-cache"
    az redis create \
        --resource-group $RG_NAME \
        --location $RG_LOC \
        --name $REDIS_NAME \
        --minimum-tls-version 1.2 \
        --sku Standard \
        --vm-size C0

Note, this ensures TLS 1.2 because <1.2 is insecure.

The next steps that create a private endpoint for the service will block public access to the service from outside the vnet.

<!--     az redis update \ -->
<!--         --name $REDIS_NAME \ -->
<!--         --resource-group $RG_NAME \ -->
<!--         --set "publicNetworkAccess"="Disabled" -->

Create the Private Endpoint:

    az network private-endpoint create \
        --resource-group $RG_NAME \
        --name "cache-private-endpoint" \
        --location $RG_LOC \
        --vnet-name $VNET_NAME \
        --subnet cache-subnet \
        --group-id "redisCache" \
        --private-connection-resource-id $(az redis show --resource-group $RG_NAME --name $REDIS_NAME | jq -r '.id') \
        --connection-name "cache-connection"

Create the Private DNS for the virtual network and link it to the virtual network:

    dns_zone_name="privatelink.redis.cache.windows.net"
    az network private-dns zone create \
        --resource-group $RG_NAME \
        --name $dns_zone_name

Link the private DNS to our vnet:

    az network private-dns link vnet create \
        --resource-group $RG_NAME \
        --zone-name $dns_zone_name \
        --name "cache-dns-link" \
        --virtual-network $VNET_NAME \
        --registration-enabled false

Create a DNS record to put to the Private Endpoint created to connect to the Storage Account:

    private_endpoint_nic_id=$(
        az network private-endpoint show \
            --resource-group $RG_NAME \
            --name cache-private-endpoint \
        | jq -r '.networkInterfaces[0].id')

    private_endpoint_ip=$(
        az network nic show \
            --ids $private_endpoint_nic_id \
        | jq -r '.ipConfigurations[0].privateIpAddress')

    az network private-dns record-set a create \
        --resource-group $RG_NAME \
        --zone-name $dns_zone_name \
        --name $REDIS_NAME \
        --output none

    az network private-dns record-set a add-record \
        --resource-group $RG_NAME \
        --zone-name $dns_zone_name \
        --record-set-name $REDIS_NAME \
        --ipv4-address $private_endpoint_ip \
        --output none

Ref: https://docs.microsoft.com/en-us/azure/azure-cache-for-redis/cache-python-get-started

Test the connection, because it's a complicated procedure:

    kubectl run check-redis-connection \
        --rm \
        -it \
        --env=fqdn=$(az redis show --name $REDIS_NAME --resource-group $RG_NAME | jq -r '.hostName') \
        --env=secret=$(az redis list-keys --name $REDIS_NAME --resource-group $RG_NAME | jq -r '.primaryKey') \
        --env=script='import os, redis; host=os.getenv("fqdn"); key=os.getenv("secret"); r=redis.from_url(f"rediss://:{key}@{host}:6380/0"); r.set("foo", "bar"); assert r.get("foo") == b"bar", r.get("foo"); r.delete("foo"); print("passed")' \
        --image python:3.10 \
        -- \
        sh -c 'python -m pip install redis; python -c "$script"'

Save the configuration settings:

    kubectl create secret generic redis-connection-secret \
        --from-literal=fqdn=$(az redis show --resource-group $RG_NAME --name $REDIS_NAME --query "hostName" --output tsv) \
        --from-literal=password=$(az redis list-keys --resource-group $RG_NAME --name $REDIS_NAME --query "primaryKey" --output tsv)


## Provisioning File Storage

Ref: https://docs.microsoft.com/en-us/azure/storage/files/storage-files-networking-endpoints?tabs=azure-cli#create-a-private-endpoint
Ref: https://blog.nillsf.com/index.php/2021/01/11/azure-files-nfs-mounted-on-azure-kubernetes-service/

FIXME: Volumes created by Helm packages that use the `default` `StorageClass` use Azure Disk. This is probably fine, but Azure services tend to be public by nature; so it's likely a good idea to look into.

The recommended way of achieving private connections between the services in a vnet and storage is to use an [Azure Private Link](https://docs.microsoft.com/en-us/azure/private-link/private-link-overview) to the storage.

We're creating the storage outside of the kubernetes cluster, but managing it dynamically within the cluster. This should give us the ability to define and organize the storage as we go.

For the list of File Storage SKUs, see https://docs.microsoft.com/en-us/azure/aks/azure-files-csi#dynamically-create-azure-files-pvs-by-using-the-built-in-storage-classes

In order to make the storage account private and allow AKS to create volumes we need to put it within AKS' managed resource group.

Lookup the AKS Resource Group:

    export AKS_RG_NAME=$(az aks show -g $RG_NAME -n $CLUSTER_NAME --query 'nodeResourceGroup' -o tsv)

Define the storage name using or be more specific by manually assigning it:

    export STORAGE_NAME=$(echo $RG_NAME | LC_ALL=C tr -dc 'a-z0-9')$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | fold -w 2 | head -n 1)

The storage name can only have alphanumeric characters. Check the name is valid using:

    az storage account check-name --name $STORAGE_NAME

Create the storage account with File Storage support:

    az storage account create \
       --name $STORAGE_NAME \
       --resource-group $AKS_RG_NAME \
       --location $RG_LOC \
       --sku Standard_LRS \
       --kind StorageV2

<!-- az storage account create \ -->
<!--     --name $STORAGE_NAME \ -->
<!--     --resource-group $AKS_RG_NAME \ -->
<!--     --location $RG_LOC \ -->
<!--     --sku Premium_LRS \ -->
<!--     --kind FileStorage -->

<!-- TODO: Are there advantages (pricing, performance, etc.) of using Premium FileStorage as opposed to Standard/Premium StorageV2? -->

Create the Private Endpoint:

    STORAGE_ID=$(az storage account show --resource-group $AKS_RG_NAME --name $STORAGE_NAME | jq -r '.id')
    az network private-endpoint create \
       --resource-group $RG_NAME \
       --name "$STORAGE_NAME-storage-private-endpoint" \
       --location $RG_LOC \
       --vnet-name $RG_NAME-vnet \
       --subnet storage-subnet \
       --group-id "file" \
       --private-connection-resource-id $STORAGE_ID \
       --connection-name "$RG_NAME-storage-connection"

<!-- List available storage group ids: `az network private-link-resource list -g $RG_NAME -n $STORAGE_NAME --type Microsoft.Storage/storageAccounts` -->

Create the Private DNS for the virtual network and link it to the virtual network:

    DNS_ZONE_NAME="privatelink.file.$(az cloud show | jq -r '.suffixes.storageEndpoint')"
    az network private-dns zone create \
       --resource-group $RG_NAME \
       --name $DNS_ZONE_NAME

Link the private DNS to our vnet:

    az network private-dns link vnet create \
       --resource-group $RG_NAME \
       --zone-name $DNS_ZONE_NAME \
       --name "$RG_NAME-file-storage-dns-link" \
       --virtual-network $RG_NAME-vnet \
       --registration-enabled false

Create a DNS record to put to the Private Endpoint created to connect to the Storage Account:

    private_endpoint_nic_id=$(az network private-endpoint show \
                              --resource-group $RG_NAME \
                              --name $STORAGE_NAME-storage-private-endpoint \
                              | jq -r '.networkInterfaces[0].id')

    private_endpoint_ip=$(az network nic show \
                          --ids $private_endpoint_nic_id \
                          | jq -r '.ipConfigurations[0].privateIpAddress')

    az network private-dns record-set a create \
       --resource-group $RG_NAME \
       --zone-name $DNS_ZONE_NAME \
       --name $STORAGE_NAME \
       --output none
    az network private-dns record-set a add-record \
       --resource-group $RG_NAME \
       --zone-name $DNS_ZONE_NAME \
       --record-set-name $STORAGE_NAME \
       --ipv4-address $private_endpoint_ip \
       --output none

Ref: https://docs.microsoft.com/en-us/azure/storage/files/storage-how-to-use-files-linux?tabs=smb311#prerequisites

Test the connection, because it's a complicated procedure:

    kubectl run check-storage-connection \
        --rm \
        -it \
        --env=httpEndpoint=$(az storage account show --resource-group $AKS_RG_NAME --name $STORAGE_NAME | jq -r '.primaryEndpoints.file') \
        --image busybox:latest \
        -- \
        sh -c 'nc -zvw3 $(echo $httpEndpoint | cut -c7-$(expr length $httpEndpoint) | tr -d "/") 445'

You should see something liket the following in the output:

    <STORAGE_NAME>.file.core.windows.net (10.1.2.X:445) open
