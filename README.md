# Wild Me Codex Deployment

This deployment uses Azure resources and services.

The notable services used:

- [AKS (Azure Kubernetes Service)](https://docs.microsoft.com/en-us/azure/aks/) - used as the server-side cloud orchestration and management of deployed applications
- [Postgres (Azure Database for Postgres)](https://docs.microsoft.com/en-us/azure/postgresql/) - used by the applications for SQL database support
- [File storage (Azure File Storage)](https://docs.microsoft.com/en-us/azure/storage/files/storage-files-introduction) - used to persist and store application data


## Prerequisite tasks

1. [Install and usage of python-dotenv (optional)](docs/python-dotenv.md)
1. [Azure Provisioning of AKS, Postgres and Redis services](docs/azure-provisioning.md)
1. [Installing and configuring Kubernetes Ingress](docs/kubernetes-ingress.md)
1. [Install and configure cert-manager](docs/cert-manager.md)
1. [Install ElasticSearch](docs/elasticsearch.md)
1. [Releasing the frontend code](docs/frontend-release.md)

### Prerequisite GitLab deployment

It's assumed that GitLab is centrally deployed outside of this deployment. See [GitLab Deployment Instructions](https://github.com/WildMeOrg/gitlab/).



## Usage

There are two parts to using this software.

1. In order to use this software, you must create or have available to you a kubernetes cluster. See [Create the cluster](#create-the-cluster) to create a cluster from scratch.
1. The primary usage of this software is to install and maintain instances of Codex. See [Install a codex instance](#install-a-codex-instance) how to create a codex install. See [Maintaining a codex instance](#maintaining-a-codex-instance) for maintaining an existing install.


### Create the cluster

1. Ensure your Azure CLI is configured to use the correct subscription.
   Use `az login` to login with the correct identity.
   View your subscriptions with `az account list --output table`.
   Select one of these by name and set it as the default subscription using:  `az account set --subscription <subscription-name>`

2. Provision the cluster and other azure resources by running:  `./bootstrap.sh provision`

3. Bootstrap the cluster with the required shared software:  `./bootstrap.sh bootstrap`

### Install a codex instance

1. Ensure you have credential access to the cluster:  `./install-credentials.sh -e $resource_group.env` where `$resource_group` is the azure resource group that contains the cluster where the instance is located.

2. Install a codex instance using: `./create.sh <your-options>` Where `<your-options>` can be filled in through options listed in the `./create.sh --help` information.

### Maintaining a codex instance

1. Ensure you have credential access to the cluster:  `./install-credentials.sh -e $resource_group.env` where `$resource_group` is the azure resource group that contains the cluster where the instance is located.

2. Configure the kubectl to use the namespace where your instance is located:  `kubectl config set-context --current --namespace=$instance_namespace`

3. You may now run any kubectl commands needed. For example, `kubectl get pods` or `kubectl logs <pod-name>`. See [Maintenance and debugging](docs/maintenance.md) for more information.

#### Editing the instance configuration

To edit the configuration: `kubectl edit configmap codex-configmap`.

To restart the houston services: `kubectl rollout restart codex-houston-api codex-houston-beat codex-houston-worker`.

#### Connecting to the database

The easiest way to establish a connection to the Postgres database is using the `connect-to-postgres.sh` script. This will give you a psql shell prompt.



## Reference

- [Azure – Move resource group to a different subscription using azure-cli](https://iamroot.it/2021/08/01/azure-move-resource-group-to-a-different-subscription-using-azure-cli/) - Possibly useful for moving an entire resource group from our development subscription to the production subscription.



## License

This software is subject to the provisions of Apache License Version 2.0 (APL). See `LICENSE` for details. Copyright (c) 2021 Wild Me
