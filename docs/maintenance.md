# Maintenance and Debugging


## Updating the backend software

To update the software, update the container.

Note: As of this writing, the containers are all `latest` tagged, which makes it difficult to upgrade and downgrade without pushing a new image with whatever fix may be needed. Also, kubernetes by default doesn't pull for new images if it has the tagged image already; unless you set `imagePullPolicy: "Always"`, which we do to work around the aforementioned issue.

There is an easy way to upgrade our software, because we use `latest` tagged image and the `imagePullPolicy: "Always"`. You can restart the _deployment_ with the latest image using:

    $ kubectl rollout restart deploy <name>

For example, to restart and upgrade the api deployment: `kubectl rollout restart deploy houston-api`.

This `rollout restart` will restart all the replicas associated with a deployment. Though, kubernetes it fairly intelligent about restarting, so it won't shutdown the current running pods/replicas until replacements are up and running; at which point it will redirect traffic and terminate the older pod(s).


## Updating the frontend software

At this time, updating the frontend is done through pushing an image that contains the build frontend. Use the same process as one would use to update the backend software.


## Viewing logs (that are on stdout)

To view the logs associated with a particular instance of, for example, houston's api process you would first determine which replica to view. This can be done by listing the pods with `kubectl get pods`, which while list all active pods in the namespace.

    $ kubectl get pods | grep houston-api
    houston-api-6dd9449ffb-qdrhw      1/1     Running     0          5d4h

In this example only one replica is running: `houston-api-6dd9449ffb-qdrhw`. The replicas are base named using the deployment name. There can be more than one replica running, which would deliver a different set of logs.

To view the logs for this pod, you use the `kubectl logs` command. The `logs` command assumes you are requesting a pod. If you have kubectl auto-completion enabled you can get tab complete of the pod names. You'll likely want to limit the logs to the last N lines and follow using something like `--tail 100 --follow`. The following is an example:

    $ kubectl logs --tail 2 --follow houston-api-6dd9449ffb-qdrhw
    [16:58:57] INFO     [werkzeug] 10.1.1.4 - - [08/Apr/2022 16:58:57] "[32mGET /api/v1/site-settings/definition/main/block HTTP/1.1[0m" 302 -                                              _internal.py:122
               INFO     [werkzeug] 10.1.1.4 - - [08/Apr/2022 16:58:57] "[32mGET /api/v1/site-settings/main/block HTTP/1.1[0m" 302 -                                                         _internal.py:122


## Getting a shell prompt inside the pod


To execute a prompt inside the pod (or execute a process) you need the name of the pod you are executing on and the command. For example, say we wanted an interactive bash prompt on a celery worker pod:

    $ kubectl exec -it houston-worker-5b757856d8-kw2kj -- bash
    root@houston-worker-5b757856d8-kw2kj:/code#

The basic format is to use `kubectl exec <options> <pod-name> -- <command>`. This can be used to execute any command available in the pod. In this example, we are executing `bash`. Keep in mind that not all containers have all the tools pre-loaded (e.g. `bash` is not present on the `elasticsearch` containers).


## Making code changes or developing on the server

You should not and really cannot make changes to the code. This setup is intended to run slated, stamped and fixed code. That doesn't mean you couldn't change code and run custom commands, it's just that the processes won't see those changes unless you put them into the originating/source image.

Long story short... It's complicated and possible to make changes, but don't do this. Instead develop in the development environment, write tests that address the problem and push the changes.

Note: If you really really needed to develop code in this deployment scenario, you'd likely need put the code in a custom volume to overwrite the container's copy of the code. This would be more trouble than it is worth, but possible.


## Getting files in an out of the server

The only way to get files to and from the server is to mount them from a volume. This can be inconvient, but there are security reasons for not allowing the transfer of files.

If you really need to utilize file data on/in the pod, the best way would be through the use of Azure Files and mounting the File Share as a volume in the pod. This allow you to upload the files from your system into the Azure File Share using the Azure portal or the Azure CLI.

The inclusion of Azure Files in a pod looks something like this:

    apiVersion: v1
    kind: Pod
    metadata:
      name: example
    spec:
      containers:
        - name: count
          image: wildme/houston:latest
          args: [/bin/sh, -c, 'sleep infinity']
          volumeMounts:
            - name: myfiles
              mountPath: /mnt/myfiles
      volumes:
        - name: myfiles
          csi:
            driver: file.csi.azure.com
            volumeAttributes:
              secretName: myfiles-azure-files-secret
              shareName: myfiles
              mountOptions: "dir_mode=0777,file_mode=0777,cache=strict,actimeo=30"

In this example, the `myfiles-azure-files-secret` secret contains the Azure Files storage name and access key. You'd create this using something like:

    kubectl create secret generic \
        myfiles-azure-files-secret \
        --from-literal=azurestorageaccountname=$STORAGE_NAME \
        --from-literal=azurestorageaccountkey=$STORAGE_KEY

See also: [load-existing-data.md](load-existing-data.md) and `_import-data.yaml` for an actual example of this that is used in the data migration process.


