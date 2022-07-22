# Install cert-manager

[cert-manager](https://cert-manager.io/) is installed as part of the bootstrapping process. There is no need to install cert-manager manually.

The following instructions illustrate how to manually install cert-manager into an existing cluster. This can be useful in understanding the moving parts of cert-manager without diving too deeply into the application itself.


## Installation

See also https://cert-manager.io/docs/installation/helm/

1. Install cert-manager's CRDs using Helm

        helm repo add jetstack https://charts.jetstack.io
        helm repo update

1. Install the cert-manager Helm chart. These basic configurations should be sufficient for many use cases, however, additional cert-manager configurable parameters can be found in [cert-manager's official Helm install documentation](https://cert-manager.io/docs/installation/helm/).

        helm upgrade --install \
            cert-manager jetstack/cert-manager \
            --namespace cert-manager \
            --create-namespace \
            --version v1.6.1 \
            --set prometheus.enabled=false \
            --set installCRDs=true

    <!-- to see available versions: `helm search jetstack/cert-manager --versions` -->
    <!-- uninstall: `helm uninstall --namespace cert-manager cert-manager` -->

1. Verify that the corresponding cert-manager pods are now running.

        kubectl get pods --namespace cert-manager

    You should see a similar output:

        NAME                                       READY   STATUS    RESTARTS   AGE
        cert-manager-8888888888-88888              1/1     Running   3          1m
        cert-manager-cainjector-8888888888-88888   1/1     Running   3          1m
        cert-manager-webhook-8888888888-88888      1/1     Running   0          1m


## Create a ClusterIssuer Resource

Now that cert-manager is installed and running on your cluster, you will need to create a ClusterIssuer resource which defines which CA can create signed certificates when a certificate request is received. A ClusterIssuer is not a namespaced resource, so it can be used by more than one namespace.

1. Using the text editor of your choice, create a file named `acme-issuer-prod.yaml` with the example configurations. Replace the value of `email` with your own email address.

    File `acme-issuer-prod.yaml`:

        apiVersion: cert-manager.io/v1
        kind: ClusterIssuer
        metadata:
          name: letsencrypt-prod
        spec:
          acme:
            email: user@example.com
            server: https://acme-v02.api.letsencrypt.org/directory
            privateKeySecretRef:
              name: letsencrypt-secret-prod
            solvers:
            - http01:
                ingress:
                  class: nginx

    - This manifest file creates a ClusterIssuer resource that will register an account on an ACME server. The value of `spec.acme.server` designates Let's Encrypt's production ACME server, which should be trusted by most browsers.

    Note, Let's Encrypt provides a staging ACME server that can be used to test issuing trusted certificates, while not worrying about hitting [Let's Encrypt's production rate limits](https://letsencrypt.org/docs/rate-limits/). The staging URL is `https://acme-staging-v02.api.letsencrypt.org/directory`.

    - The value of `privateKeySecretRef.name` provides the name of a secret containing the private key for this user's ACME server account (this is tied to the email address you provide in the manifest file). The ACME server will use this key to identify you.
    - To ensure that you own the domain for which you will create a certificate, the ACME server will issue a challenge to a client. cert-manager provides two options for solving challenges, [`http01`](https://cert-manager.io/docs/configuration/acme/http01/) and [`DNS01`](https://cert-manager.io/docs/configuration/acme/dns01/). In this example, the `http01` challenge solver will be used and it is configured in the `solvers` array. cert-manager will spin up *challenge solver* Pods to solve the issued challenges and use Ingress resources to route the challenge to the appropriate Pod.


## Create a Certificate Resource

After you have a ClusterIssuer resource, you can create a Certificate resource. This will describe your [x509 public key certificate](https://en.wikipedia.org/wiki/X.509) and will be used to automatically generate a [CertificateRequest](https://cert-manager.io/docs/concepts/certificaterequest/) which will be sent to your ClusterIssuer.

1. Using the text editor of your choice, create a file named `certificate-prod.yaml` with the example configurations. Replace the value of `email` with your own email address. Replace the value of `spec.dnsNames` with your own domain that you will use to host.

    File `certificate-prod.yaml`

        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: example-prod
        spec:
          secretName: letsencrypt-secret-prod
          duration: 2160h # 90d
          renewBefore: 360h # 15d
          issuerRef:
            name: letsencrypt-prod
            kind: ClusterIssuer
          dnsNames:
          - foo.example.com

    The configurations in this example create a Certificate that is valid for 90 days and renews 15 days before expiry.

1. Create the Certificate resource:

        kubectl create -f certificate-prod.yaml

1. Verify that the Certificate has been successfully issued:

        kubectl get certs

    When your certificate is ready, you should see a similar output:

        NAME                   READY   SECRET                    AGE
        example-prod   True    letsencrypt-secret-prod   42s

    All the necessary components are now in place to be able to enable HTTPS on your service. In the next section, you will complete the steps need to deploy.
