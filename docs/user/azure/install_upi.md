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

### Create install config

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

#### Empty the compute pool

We'll be providing the control-plane and compute machines ourselves, so edit the resulting `install-config.yaml` to set `replicas` to 0 for the `compute` pool:

```sh
python -c '
import yaml;
path = "install-config.yaml";
data = yaml.full_load(open(path));
data["compute"][0]["replicas"] = 0;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'
```

#### Extract data from install config

Some data from the install configuration will be used on later steps. Export them as environment variables with:

```sh
export CLUSTER_NAME=`yq -r .metadata.name install-config.yaml`
export AZURE_REGION=`yq -r .platform.azure.region install-config.yaml`
export SSH_KEY=`yq -r .sshKey install-config.yaml`
export BASE_DOMAIN=`yq -r .baseDomain install-config.yaml`
```

### Create The Resource Group

All resources created as part of this Azure deployment will exist as part of a resource group. Use the commands
below to create it in the selected Azure region. In this example we're going to use the cluster name as the unique
resource group name, but feel free to choose any other name and export it in the RESOURCE_GROUP environment variable,
which will be used in the subsequent steps.

```sh
export RESOURCE_GROUP=$CLUSTER_NAME

az group create --name $RESOURCE_GROUP --location $AZURE_REGION
az identity create -g $RESOURCE_GROUP -n ${RESOURCE_GROUP}_userid
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
VNet and subnet names, resource group name, and so on. Also, we you don't want [the ingress operator][ingress-operator] to
create DNS records so we need to remove the `privateZone` and `publicZone` sections from the DNS configuration in manifests.

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
├── 04_bootstrap.template.json
├── 05_masters.json
├── 05_masters.template.json
├── 06_workers.json
├── 06_workers.template.json
├── auth
│   ├── kubeadmin-password
│   └── kubeconfig
├── bootstrap.ign
├── master.ign
├── master.json
├── metadata.json
├── node.json
├── setup-manifests.py
├── setup-parameters.py
└── worker.ign
```

### Infra ID

The OpenShift cluster has been assigned an identifier in the form of `<cluster name>-<random string>`. You do not need this for anything, but it is a good idea to keep it around.
You can see the various metadata about your future cluster in `metadata.json`.

The Infra ID is under the `infraID` key:

```console
$ export INFRA_ID=$(jq -r .infraID metadata.json)
$ echo $INFRA_ID
openshift-vw4j5
```

### Create a Storage Account

Create a storage account and export its key as an environment variable.

```sh
az storage account create -g $RESOURCE_GROUP --location $AZURE_REGION --name sa${CLUSTER_NAME} --kind Storage --sku Standard_LRS
export ACCOUNT_KEY=`az storage account keys list -g $RESOURCE_GROUP --account-name sa${CLUSTER_NAME} --query "[0].value" -o tsv`
```

### Copy the cluster image

Given the size of the Red Hat Enterprise Linux CoreOS virtual hard disk, it's not possible to run the required commands
with the image stored locally. We must copy and store it in a storage container instead. To do so, first locate the latest RHCOS
image (or any other version as desired) and export its URL to an environment variable.

```sh
export VHD_URL=`curl -s https://raw.githubusercontent.com/openshift/installer/master/data/data/rhcos.json | jq -r .azure.url`
```

Create a blob storage container and copy the image:

```sh
az storage container create --name vhd --account-name sa${CLUSTER_NAME}
az storage blob copy start --account-name sa${CLUSTER_NAME} --account-key "$ACCOUNT_KEY" --destination-blob "rhcos.vhd" --destination-container vhd --source-uri "$VHD_URL"
```

To track the progress, you can use:

```sh
status="unknown"
while [ "$status" != "success" ]
do
    status=`az storage blob show --container-name vhd --name "rhcos.vhd" --account-name sa${CLUSTER_NAME} --account-key $ACCOUNT_KEY -o tsv --query properties.copy.status`
done
```

### Upload the ignition file

Create a blob storage container and upload the bootstrap.ign file:

```sh
az storage container create --name files --account-name sa${CLUSTER_NAME} --public-access blob
az storage blob upload --account-name sa${CLUSTER_NAME} --account-key $ACCOUNT_KEY -c "files" -f "bootstrap.ign" -n "bootstrap.ign"
export BOOTSTRAPURL=`az storage blob url --account-name sa${CLUSTER_NAME} --account-key $ACCOUNT_KEY -c "files" -n "bootstrap.ign" -o tsv`
```

### Create a template parameters file

The key part of this UPI deployment are the [Azure Resource Manager][azuretemplates] templates, which are responsible
for deploying most resources. The templated exposes some of its configurations as deployment parameters in separate templates.
Run the Python script below to generate the `*.parameters.json` files based on the generated ignition files.

```sh
python3 setup-parameters.py $BOOTSTRAPURL sa${CLUSTER_NAME} "${SSH_KEY}"
```

## Deployment

### Deploy the VPC

```sh
az group deployment create -g $RESOURCE_GROUP --name 01_${CLUSTER_NAME} --template-file "01_vpc.json"
```

### Deploy the storage account

```sh
az group deployment create -g $RESOURCE_GROUP --name 02_${CLUSTER_NAME} --template-file "02_storage.json"
```

### Deploy the load balancers

Create the public IP addresses:

```sh
az network public-ip create -g $RESOURCE_GROUP -n $CLUSTER_NAME --allocation-method static --sku Standard
az network public-ip create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}app --allocation-method static --sku Standard
```

```sh
az group deployment create -g $RESOURCE_GROUP --name 03_${CLUSTER_NAME} --template-file "03_infra.json"
```

Create DNS records for the public load balancer:

```sh
export PUBLIC_IP=`az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${CLUSTER_NAME}'] | [0].ipAddress" -o tsv`
export PUBLIC_IP_APPS=`az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${CLUSTER_NAME}app'] | [0].ipAddress" -o tsv`

az network dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}

az network dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api --ttl 60
az network dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps --ttl 300

az network dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api -a $PUBLIC_IP
az network dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps -a $PUBLIC_IP_APPS
```

Create private DNS records for the internal load balancer:

```sh
export INTERNAL_LB_IP=`az network lb frontend-ip show -g $RESOURCE_GROUP --lb-name ${RESOURCE_GROUP}intlb -n LoadBalancerFrontEnd --query "privateIpAddress" -o tsv`

az network private-dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns link vnet create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n ${CLUSTER_NAME}-private-dns-vnet -v openshiftVnet -e false

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api-int --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api -a $INTERNAL_LB_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api-int -a $INTERNAL_LB_IP
```

### Launch the temporary cluster bootstrap

```sh
az group deployment create -g $RESOURCE_GROUP --name 04_${CLUSTER_NAME} --template-file "04_bootstrap.json" --parameters "04_bootstrap.parameters.json"
```

Create private DNS records for the bootstrap:

```sh
export BOOTSTRAP_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name bootstrap-0nic -n ipconfig1 --query "privateIpAddress" -o tsv`

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n bootstrap-0 --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n bootstrap-0 -a $BOOTSTRAP_IP

az network private-dns record-set srv create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp --ttl 60
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t bootstrap-0.${CLUSTER_NAME}.${BASE_DOMAIN}
```

### Deploy the masters

```sh
az group deployment create -g $RESOURCE_GROUP --name 05_${CLUSTER_NAME} --template-file "05_masters.json" --parameters "05_masters.parameters.json"
```

Create private DNS records for the control plane:

```sh
export MASTER0_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name master01nic -n ipconfig1 --query "privateIpAddress" -o tsv`
export MASTER1_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name master02nic -n ipconfig1 --query "privateIpAddress" -o tsv`
export MASTER2_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name master03nic -n ipconfig1 --query "privateIpAddress" -o tsv`

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-0 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-1 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-2 --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-0 -a $MASTER0_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-1 -a $MASTER1_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-2 -a $MASTER2_IP

az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}
```

### Access the OpenShift API

You can use the `oc` or `kubectl` commands to talk to the OpenShift API. The admin credentials are in `auth/kubeconfig`:

```sh
export KUBECONFIG="$PWD/auth/kubeconfig"
oc get nodes
oc get clusteroperator
```

**NOTE**: Only the API will be up at this point. The OpenShift web console will run on the compute nodes.

### Deploy the workers

```sh
az group deployment create -g $RESOURCE_GROUP --name 06_${CLUSTER_NAME} --template-file "06_workers.json" --parameters "06_workers.parameters.json"
```

### Approve the worker CSRs

TODO improve this section, actual console output

Even after they've booted up, the workers will not show up in `oc get nodes`.

Instead, they will create certificate signing requests (CSRs) which need to be approved. You can watch for the CSRs here:

```sh
$ watch oc get csr -A
```

Eventually, you should see `Pending` entries looking like this

```sh
$ oc get csr -A
NAME        AGE    REQUESTOR                                                                   CONDITION
csr-2scwb   16m    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-5jwqf   16m    system:node:openshift-qlvwv-master-0                                         Approved,Issued
csr-88jp8   116s   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
csr-9dt8f   15m    system:node:openshift-qlvwv-master-1                                         Approved,Issued
csr-bqkw5   16m    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-dpprd   6s     system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
csr-dtcws   24s    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
csr-lj7f9   16m    system:node:openshift-qlvwv-master-2                                         Approved,Issued
csr-lrtlk   15m    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-wkm94   16m    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
```

You should inspect each pending CSR and verify that it comes from a node you recognise:

```
$ oc describe csr csr-88jp8
Name:               csr-88jp8
Labels:             <none>
Annotations:        <none>
CreationTimestamp:  Wed, 23 Oct 2019 13:22:51 +0200
Requesting User:    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper
Status:             Pending
Subject:
         Common Name:    system:node:openshift-qlvwv-worker-0
         Serial Number:
         Organization:   system:nodes
Events:  <none>
```

If it does (this one is for `openshift-qlvwv-worker-0` which we've created earlier), you can approve it:

```sh
$ oc adm certificate approve csr-88jp8
```

Approved nodes should now show up in `oc get nodes`, but they will be in the `NotReady` state. They will create a second CSR which you should also review:

```sh
$ oc get csr -A
NAME        AGE     REQUESTOR                                                                   CONDITION
csr-2scwb   17m     system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-5jwqf   17m     system:node:openshift-qlvwv-master-0                                         Approved,Issued
csr-7mv4d   13s     system:node:openshift-qlvwv-worker-1                                         Pending
csr-88jp8   3m29s   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-9dt8f   17m     system:node:openshift-qlvwv-master-1                                         Approved,Issued
csr-bqkw5   18m     system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-bx7p4   28s     system:node:openshift-qlvwv-worker-0                                         Pending
csr-dpprd   99s     system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-dtcws   117s    system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-lj7f9   17m     system:node:openshift-qlvwv-master-2                                         Approved,Issued
csr-lrtlk   17m     system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-wkm94   18m     system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Approved,Issued
csr-wqpfd   21s     system:node:openshift-qlvwv-worker-2                                         Pending
```

(we see the CSR approved earlier as well as a new `Pending` one for the same node: `openshift-qlvwv-worker-0`)

And approve:

```sh
$ oc adm certificate approve csr-bx7p4
```

Once this CSR is approved, the node should switch to `Ready` and pods will be scheduled on it.

### Wait for the bootstrap and installation complete

Wait until cluster bootstrapping has completed:

```sh
openshift-install wait-for bootstrap-complete --log-level debug
```

Wait until cluster is ready:

```sh
openshift-install wait-for install-complete --log-level debug
```

### Post-installation cleanup

Once the installation is complete you can deallocate and delete bootstrap resources:

```sh
az vm stop -g $RESOURCE_GROUP --name bootstrap-0
az vm deallocate -g $RESOURCE_GROUP --name bootstrap-0 --no-wait
az storage blob delete --account-key $ACCOUNT_KEY --account-name sa${CLUSTER_NAME} --container-name files --name bootstrap.ign
```

[azuretemplates]: https://docs.microsoft.com/en-us/azure/azure-resource-manager/template-deployment-overview
[openshiftinstall]: https://github.com/openshift/installer
[azurecli]: https://docs.microsoft.com/en-us/cli/azure/
[jqjson]: https://stedolan.github.io/jq/
[yqyaml]: https://yq.readthedocs.io/en/latest/
[ingress-operator]: https://github.com/openshift/cluster-ingress-operator
[machine-api-operator]: https://github.com/openshift/machine-api-operator
