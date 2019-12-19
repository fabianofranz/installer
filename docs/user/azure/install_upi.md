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
VNet and subnet names, and so on. Also, we you don't want [the ingress operator][ingress-operator] to create DNS records so we need
to remove the `privateZone` and `publicZone` sections from the DNS configuration in manifests.

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
├── auth
│   ├── kubeadmin-password
│   └── kubeconfig
├── azuredeploy.json
├── azuredeploy.parameters.json
├── bootstrap.ign
├── master.ign
├── master.json
├── metadata.json
├── node.json
├── setup-manifests.py
├── setup-variables.py
└── worker.ign
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
for deploying most resources. The template exposes some of its configurations as deployment parameters in a separate template.
Run the Python script below to generate the `runit.parameters.json` file based on the generated ignition files.

```sh
python3 setup-variables.py $BOOTSTRAPURL sa${CLUSTER_NAME} "${SSH_KEY}"
```

## Deployment

### Deploy the VPC

```sh
az group deployment create -g $RESOURCE_GROUP --name 01_${CLUSTER_NAME} --template-file "01_vpc.json"
```

### Create IPs, load balancers and DNS records

Create the public IP addresses:

```sh
az network public-ip create -g $RESOURCE_GROUP -n $CLUSTER_NAME --allocation-method static
az network public-ip create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}app --allocation-method static
```

Create the internal DNS entries:

```sh
az network private-dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}

az network private-dns record-set srv create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp --ttl 60
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t bootstrap-0.${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n bootstrap-0 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-0 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-1 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-2 --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n bootstrap-0 -a 10.0.0.4
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-0 -a 10.0.0.5
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-1 -a 10.0.0.6
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-2 -a 10.0.0.7

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api-int --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api -a 10.0.0.63
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api-int -a 10.0.0.63
```

Create the external DNS entries:

```sh
export PUBLIC_IP=`az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${CLUSTER_NAME}'] | [0].ipAddress" -o tsv`
export PUBLIC_IP_APPS=`az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${CLUSTER_NAME}app'] | [0].ipAddress" -o tsv`

az network dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}

az network dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api --ttl 60
az network dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps --ttl 300

az network dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api -a $PUBLIC_IP
az network dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps -a $PUBLIC_IP_APPS
```

Deploy the load balancers:

```sh
az group deployment create -g $RESOURCE_GROUP --name 02_${CLUSTER_NAME} --template-file "02_infra.json"
```

### Deploy the storage accounts

```sh
az group deployment create -g $RESOURCE_GROUP --name 03_${CLUSTER_NAME} --template-file "03_storage.json"
```

### Launch the temporary cluster bootstrap

```sh
az group deployment create -g $RESOURCE_GROUP --name 04_${CLUSTER_NAME} --template-file "04_bootstrap.json" --parameters "runit.parameters.json"
```

### Deploy the masters and workers

```sh
az group deployment create -g $RESOURCE_GROUP --name 05_${CLUSTER_NAME} --template-file "05_machines.json" --parameters "runit.parameters.json"
```

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
