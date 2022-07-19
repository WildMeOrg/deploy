# Elasticsearch

Ref: https://github.com/elastic/helm-charts/tree/main/elasticsearch

Ref: https://www.elastic.co/blog/how-to-run-elastic-cloud-on-kubernetes-from-azure-kubernetes-service
Ref: https://talkcloudlytome.com/setting-up-your-own-elk-stack-in-kubernetes-with-azure-aks/
Ref: https://docs.microsoft.com/en-us/learn/modules/deploy-elastic-cloud-kubernetes-azure/

## Install

Add the elastic helm repo to gain access to their charts:

    helm repo add elastic https://helm.elastic.co
    helm update

Install elasticsearch:

    helm upgrade --install \
        elasticsearch elastic/elasticsearch \
        --set replicas=1 \
        --set minimumMasterNodes=1

<!-- to see available versions: `helm search elastic/elasticsearch --versions` -->
<!-- uninstall: `helm uninstall --namespace elasticsearch elasticsearch` -->

Follow the instructions in the output. Note, it does take a while for the elasticsearch processes to come online.

FIXME: the helm chart is designed to run on a >=3 node cluster. The above doesn't quite work, but does appear to start the service if the numbers are toggled up to 2 and then back to 1.
