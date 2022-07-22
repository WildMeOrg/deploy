# Install the NGINX Ingress Controller

Ref: https://docs.microsoft.com/en-us/azure/aks/ingress-basic
Ref: https://docs.microsoft.com/en-us/azure/aks/static-ip
Ref: https://docs.microsoft.com/en-us/azure/aks/ingress-static-ip

An [*Ingress*](https://kubernetes.io/docs/concepts/services-networking/ingress/) is used to provide external routes, via HTTP or HTTPS, to your cluster's services. An *Ingress Controller*, like [the NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/deploy/#using-helm), fulfills the requirements presented by the Ingress using a load balancer.

Note, the installation of nginx-ingress is done during the bootstrap process. This documentation can be useful for fully understanding the parts involved in the process.

## Installation

In this section, you will install the NGINX Ingress Controller using Helm, which will create a NodeBalancer to handle your cluster's traffic.

1. Add the kubernetes Helm repository to your Helm repos:

        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

1. Update your Helm repositories:

        helm repo update

1. Make a namespace for the ingress controller:

        export INGRESS_CTL_NS="<your-choosen-name>"

1. Make note of the public IP address to assign:

        export PUBLIC_IP=$(az network public-ip show --resource-group $(az aks show -g $RG_NAME -n $CLUSTER_NAME --query 'nodeResourceGroup' -o tsv) --name "$RG_NAME-public-ip" --query "ipAddress" --output tsv)

1. Install the NGINX Ingress Controller. This installation will result in a NodeBalancer being created.

        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
            --timeout 600s \
            --version 4.0.15 \
            --create-namespace \
            --namespace $INGRESS_CTL_NS \
            --set controller.service.loadBalancerIP=$PUBLIC_IP \
            --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=${RG_NAME}-$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | fold -w 2 | head -n 1)

<!-- uninstall: `helm uninstall --namespace $INGRESS_CTL_NS ingress-nginx` -->

## Update your Subdomain's IP Address

### Using a custom domain:

1. Access your NodeBalancer's assigned external IP address.

        echo "$(kubectl --namespace $INGRESS_CTL_NS get services -o json ingress-nginx-controller | jq -r '.status.loadBalancer.ingress[0].ip') =? $PUBLIC_IP"

   Note, this IP should match `PUBLIC_IP`

1. Copy the IP address. Navigate to your DNS manager and add/update an 'A' record with the cluster's external IP address. Ensure that the entry's **TTL** field is set to **5 to 30 minutes**.

1. Set the domain in the configmap key 'serving_domain' to value 'codex.example.com'

### Using the azure created domain:

1. Set the domain in the configmap key 'serving_domain' to the value of:

        az network public-ip show --name $RG_NAME-public-ip --resource-group $(az aks show -g $RG_NAME -n $CLUSTER_NAME --query 'nodeResourceGroup' -o tsv) | jq -r '.dnsSettings.fqdn'

1. Update the `dnsNames` value in codex-certificate resource with the same value.
