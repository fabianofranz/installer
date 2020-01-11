# Install: User Provided Infrastructure (UPI)

The steps for performing a user-provided infrastructure install are outlined here. Several
[Azure Resource Manager][azuretemplates] templates are provided to assist in
completing these steps or to help model your own. You are also free to create
the required resources through other methods; the templates are just an
example.

## Prerequisites

* all prerequisites from [README](README.md)
* the following binaries installed and in $PATH:
  * [openshift-install][openshiftinstall]
  * [az (Azure CLI)][azurecli] installed and aunthenticated
  * python3
  * [jq][jqjson]
  * [yq][yqyaml]
* python dotmap library: install it with `pip install dotmap`

## Setup

The machines will be started manually. Therefore, it is required to generate
the bootstrap and machine ignition configs and store them for later steps.

### Create an install config

Create an install configuration as for [the usual approach](install.md#create-configuration):

```console
$ openshift-install create install-config
? SSH Public Key /home/user_id/.ssh/id_rsa.pub
? Platform azure
? azure subscription id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
? azure tenant id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
? azure service principal client id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
? azure service principal client secret xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
INFO Saving user credentials to "/home/user_id/.azure/osServicePrincipal.json"
? Region centralus
? Base Domain example.com
? Cluster Name test
? Pull Secret [? for help]
```

#### Extract data from install config

Some data from the install configuration file will be used on later steps. Export them as environment variables with:

```sh
export CLUSTER_NAME=`yq -r .metadata.name install-config.yaml`
export AZURE_REGION=`yq -r .platform.azure.region install-config.yaml`
export SSH_KEY=`yq -r .sshKey install-config.yaml | xargs`
export BASE_DOMAIN=`yq -r .baseDomain install-config.yaml`
export RESOURCE_GROUP=$CLUSTER_NAME
```

### Empty the compute pool (optional)

If you do not want the cluster to provision compute machines, edit the resulting `install-config.yaml` to set `replicas` to 0 for the `compute` pool.

```sh
python -c '
import yaml;
path = "install-config.yaml";
data = yaml.full_load(open(path));
data["compute"][0]["replicas"] = 0;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'
```

### Create manifests

Create manifests to enable customizations that are not exposed via the install configuration.

```console
$ openshift-install create manifests
INFO Credentials loaded from file "/home/user_id/.azure/osServicePrincipal.json"
INFO Consuming "Install Config" from target directory
```

#### Update manifests

The manifests need to reflect the resources to be created by the [Azure Resource Manager][azuretemplates] template, e.g. the
resource group name. Also, we you don't want [the ingress operator][ingress-operator] to create DNS records (we're going to
do it manually) so we need to remove the `privateZone` and `publicZone` sections from the DNS configuration in manifests.

A Python script is provided to help with these changes in manifests. Run it with:

```sh
python3 setup-manifests.py $RESOURCE_GROUP
```

#### Remove control plane machines and machinesets

Remove the control plane machines and compute machinesets from the manifests.
We'll be providing those ourselves and don't want to involve the [machine-API operator][machine-api-operator].

```sh
rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml
```

#### Create manifest for the ingress controller

```sh
cat > manifests/ingress-controller-02-default.yaml <<EOF
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  finalizers:
  - ingresscontroller.operator.openshift.io/finalizer-ingresscontroller
  name: default
  namespace: openshift-ingress-operator
spec:
  endpointPublishingStrategy:
    type: HostNetwork
  replicas: 3
EOF
```

### Create ignition configs

Now we can create the bootstrap ignition configs:

```console
$ openshift-install create ignition-configs
INFO Consuming Openshift Manifests from target directory
INFO Consuming Worker Machines from target directory
INFO Consuming Common Manifests from target directory
INFO Consuming Master Machines from target directory
```

After running the command, several files will be available in the directory.

```console
$ tree
.
├── 01_vpc.json
├── 02_infra.json
├── 02_storage.json
├── 03_infra.json
├── 04_bootstrap.json
├── 05_masters.json
├── 06_workers.json
├── auth
│   ├── kubeadmin-password
│   └── kubeconfig
├── bootstrap.ign
├── master.ign
├── metadata.json
├── setup-bootstrap-ignition.py
├── setup-manifests.py
└── worker.ign
```

### Infra ID

The OpenShift cluster has been assigned an identifier in the form of `<cluster name>-<random string>`. You do not need this for anything in this example, but it is a good idea to keep it around.
You can see the various metadata about your future cluster in `metadata.json`.

The Infra ID is under the `infraID` key:

```console
$ export INFRA_ID=$(jq -r .infraID metadata.json)
$ echo $INFRA_ID
openshift-vw4j5
```

### Create The Resource Group

All resources created as part of this Azure deployment will exist as part of a resource group. Use the commands
below to create it in the selected Azure region. In this example we're going to use the cluster name as the unique
resource group name, but feel free to choose any other name and export it in the RESOURCE_GROUP environment variable,
which will be used in the subsequent steps.

```sh

az group create --name $RESOURCE_GROUP --location $AZURE_REGION
az identity create -g $RESOURCE_GROUP -n ${RESOURCE_GROUP}-identity
```

### Create a Storage Account

Create a storage account that will be used to store the cluster VHD image and the ignition files. Wxport its key as an environment variable.

```sh
az storage account create -g $RESOURCE_GROUP --location $AZURE_REGION --name ${CLUSTER_NAME}sa --kind Storage --sku Standard_LRS
export ACCOUNT_KEY=`az storage account keys list -g $RESOURCE_GROUP --account-name ${CLUSTER_NAME}sa --query "[0].value" -o tsv`
```

### Copy the cluster image

Given the size of the Red Hat Enterprise Linux CoreOS virtual hard disk (VHD), it's not possible to run the required commands
with the image stored locally. We must copy and store it in a storage container instead. To do so, first locate the latest RHCOS
image (or any other version as desired) and export its URL to an environment variable.

```sh
export VHD_URL=`curl -s https://raw.githubusercontent.com/openshift/installer/master/data/data/rhcos.json | jq -r .azure.url`
```

Create a blob storage container and copy the image to it:

```sh
az storage container create --name vhd --account-name ${CLUSTER_NAME}sa
az storage blob copy start --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY --destination-blob "rhcos.vhd" --destination-container vhd --source-uri "$VHD_URL"
```

To track the progress, you can use:

```sh
status="unknown"
while [ "$status" != "success" ]
do
  status=`az storage blob show --container-name vhd --name "rhcos.vhd" --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -o tsv --query properties.copy.status`
  echo $status
done
```

Store the blob URL of the copied image for later use:

```sh
export VHD_BLOB_URL=`az storage blob url --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c vhd -n "rhcos.vhd" -o tsv`
```

### Upload the ignition file

Create a blob storage container and upload the bootstrap.ign file:

```sh
az storage container create --name files --account-name ${CLUSTER_NAME}sa --public-access blob
az storage blob upload --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c "files" -f "bootstrap.ign" -n "bootstrap.ign"

export BOOTSTRAP_URL=`az storage blob url --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c "files" -n "bootstrap.ign" -o tsv`
```

## Deployment

The key part of this UPI deployment are the [Azure Resource Manager][azuretemplates] templates, which are responsible
for deploying most resources. They're provided as a few json files named following the "NN_name.json" pattern. In the
next steps we're going to deploy each one of them in order, providing the expected parameters.

### Deploy the VPC

```sh
az group deployment create -g $RESOURCE_GROUP \
  --template-file "01_vpc.json"
```

### Deploy the storage account

```sh
az group deployment create -g $RESOURCE_GROUP \
  --template-file "02_storage.json" \
  --parameters vhdBlobURL="${VHD_BLOB_URL}"
```

### Deploy the load balancers

Deploy the load balancers and public IP addresses:

```sh
az group deployment create -g $RESOURCE_GROUP \
  --template-file "03_infra.json"
```

Create DNS records for the public load balancer:

```sh
export PUBLIC_IP=`az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${CLUSTER_NAME}-master-pip'] | [0].ipAddress" -o tsv`
export PUBLIC_IP_APPS=`az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${CLUSTER_NAME}-infra-pip'] | [0].ipAddress" -o tsv`

az network dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}

az network dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api --ttl 60
az network dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps --ttl 300

az network dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api -a $PUBLIC_IP
az network dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps -a $PUBLIC_IP_APPS
```

Create private DNS records for the internal load balancer:

```sh
export INTERNAL_LB_IP=`az network lb frontend-ip show -g $RESOURCE_GROUP --lb-name ${RESOURCE_GROUP}-internal-lb -n internal-lb-ip --query "privateIpAddress" -o tsv`

az network private-dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns link vnet create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n ${CLUSTER_NAME}-private-dns-vnet -v "${RESOURCE_GROUP}-vnet" -e true

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api-int --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api -a $INTERNAL_LB_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api-int -a $INTERNAL_LB_IP
```

### Launch the temporary cluster bootstrap

```sh
az group deployment create -g $RESOURCE_GROUP \
  --template-file "04_bootstrap.json" \
  --parameters bootstrapIgnition="`python3 setup-bootstrap-ignition.py $BOOTSTRAP_URL`" \
  --parameters sshKeyData="$SSH_KEY"
```

Create private DNS records for the bootstrap:

```sh
export BOOTSTRAP_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-bootstrap-nic -n ipconfig1 --query "privateIpAddress" -o tsv`

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n bootstrap-0 --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n bootstrap-0 -a $BOOTSTRAP_IP

az network private-dns record-set srv create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp --ttl 60
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t bootstrap-0.${CLUSTER_NAME}.${BASE_DOMAIN}
```

### Deploy the masters

```sh
az group deployment create -g $RESOURCE_GROUP \
  --template-file "05_masters.json" \
  --parameters masterIgnition="`cat master.ign | base64`" \
  --parameters sshKeyData="$SSH_KEY"
```

Create private DNS records for the control plane:

```sh
export MASTER0_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-master-01-nic -n ipconfig1 --query "privateIpAddress" -o tsv`
export MASTER1_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-master-02-nic -n ipconfig1 --query "privateIpAddress" -o tsv`
export MASTER2_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-master-03-nic -n ipconfig1 --query "privateIpAddress" -o tsv`

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-0 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-1 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-2 --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-0 -a $MASTER0_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-1 -a $MASTER1_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-2 -a $MASTER2_IP

az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 0 -w 10 -t etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 0 -w 10 -t etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 0 -w 10 -t etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}
```

### Wait for the bootstrap complete

Wait until cluster bootstrapping has completed:

```console
$ openshift-install wait-for bootstrap-complete --log-level debug
DEBUG OpenShift Installer v4.n
DEBUG Built from commit 6b629f0c847887f22c7a95586e49b0e2434161ca
INFO Waiting up to 30m0s for the Kubernetes API at https://api.basedomain.com:6443...
DEBUG Still waiting for the Kubernetes API: the server could not find the requested resource
DEBUG Still waiting for the Kubernetes API: the server could not find the requested resource
DEBUG Still waiting for the Kubernetes API: the server could not find the requested resource
DEBUG Still waiting for the Kubernetes API: Get https://api.basedomain.com:6443/version?timeout=32s: dial tcp: connect: connection refused
INFO API v1.14.n up
INFO Waiting up to 30m0s for bootstrapping to complete...
DEBUG Bootstrap status: complete
INFO It is now safe to remove the bootstrap resources
```

Once the bootstrapping process is complete you can deallocate and delete bootstrap resources:

```sh
az vm stop -g $RESOURCE_GROUP --name ${RESOURCE_GROUP}-bootstrap
az vm deallocate -g $RESOURCE_GROUP --name ${RESOURCE_GROUP}-bootstrap --no-wait
az storage blob delete --account-key $ACCOUNT_KEY --account-name ${CLUSTER_NAME}sa --container-name files --name bootstrap.ign
```

### Access the OpenShift API

You can use the `oc` or `kubectl` commands to talk to the OpenShift API. The admin credentials are in `auth/kubeconfig`. For example:

```sh
export KUBECONFIG="$PWD/auth/kubeconfig"
oc get nodes
oc get clusteroperator
```

**NOTE**: Only the API will be up at this point. The OpenShift web console will run on the compute nodes.

### Deploy the workers

```sh
export PRINCIPAL_ID=`az identity show -g $RESOURCE_GROUP -n ${RESOURCE_GROUP}-identity --query principalId --out tsv`
export RESOURCE_GROUP_ID=`az group show -g $RESOURCE_GROUP --query id --out tsv`
az role assignment create --assignee $PRINCIPAL_ID --role 'Contributor' --scope $RESOURCE_GROUP_ID

az group deployment create -g $RESOURCE_GROUP \
  --template-file "06_workers.json" \
  --parameters workerIgnition="`cat worker.ign | base64`" \
  --parameters sshKeyData="$SSH_KEY"
```

### Approve the worker CSRs

Even after they've booted up, the workers will not show up in `oc get nodes`.

Instead, they will create certificate signing requests (CSRs) which need to be approved. Eventually, you should see `Pending` entries looking like this

```console
$ oc get csr -A
NAME        AGE    REQUESTOR                                                                   CONDITION
csr-576l2   19m    system:node:master03                                                        Approved,Issued
csr-5ztvt   19m    system:node:master02                                                        Approved,Issued
csr-8bppf   2m8s   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
csr-dj2w4   112s   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
csr-htmtm   19m    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-ph8s8   11s    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
csr-q7f6q   19m    system:node:master01                                                        Approved,Issued
csr-wpvxq   19m    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-xpp49   19m    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
```

You should inspect each pending CSR with the `oc describe csr <name>` command and verify that it comes from a node you recognise. If it does, they can be approved:

```console
$ oc adm certificate approve csr-8bppf csr-dj2w4 csr-ph8s8
certificatesigningrequest.certificates.k8s.io/csr-8bppf approved
certificatesigningrequest.certificates.k8s.io/csr-dj2w4 approved
certificatesigningrequest.certificates.k8s.io/csr-ph8s8 approved
```

Approved nodes should now show up in `oc get nodes`, but they will be in the `NotReady` state. They will create a second CSR which must also be reviewed and approved:

```console
$ oc get csr -A
NAME        AGE     REQUESTOR                                                                   CONDITION
csr-882gw   35s     system:node:node03                                                          Pending
csr-cxgk9   38s     system:node:node02                                                          Pending
csr-wjdfw   34s     system:node:node01                                                          Pending
csr-8bppf   3m37s   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
...
```

Once all CSR's are approved, the node should switch to `Ready` and pods will be scheduled on it.

```console
$ oc get nodes
NAME       STATUS   ROLES    AGE     VERSION
master01   Ready    master   23m     v1.14.6+cebabbf7a
master02   Ready    master   23m     v1.14.6+cebabbf7a
master03   Ready    master   23m     v1.14.6+cebabbf7a
node01     Ready    worker   2m30s   v1.14.6+cebabbf7a
node02     Ready    worker   2m35s   v1.14.6+cebabbf7a
node03     Ready    worker   2m34s   v1.14.6+cebabbf7a
```

### Wait for the installation complete

Wait until cluster is ready:

```sh
openshift-install wait-for install-complete --log-level debug
```

[azuretemplates]: https://docs.microsoft.com/en-us/azure/azure-resource-manager/template-deployment-overview
[openshiftinstall]: https://github.com/openshift/installer
[azurecli]: https://docs.microsoft.com/en-us/cli/azure/
[jqjson]: https://stedolan.github.io/jq/
[yqyaml]: https://yq.readthedocs.io/en/latest/
[ingress-operator]: https://github.com/openshift/cluster-ingress-operator
[machine-api-operator]: https://github.com/openshift/machine-api-operator
