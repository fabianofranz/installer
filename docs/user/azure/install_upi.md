# Install: User Provided Infrastructure (UPI)

The steps for performing a user-provided infrastructure install are outlined here. Several
[Azure Resource Manager][azuretemplates] templates are provided to assist in
completing these steps or to help model your own. You are also free to create
the required resources through other methods; the templates are just an
example.

## Overview

This creates:

    A Resource Group
    3 Masters
    3-16 Workers
    A API Loadbalancer
    A Application Loadbalancer
    2 Availablity Groups

## Prerequisites

* all prerequisites from [README](README.md)
* the following binaries installed and in $PATH:
  * [openshift-install][openshiftinstall]
<<<<<<< HEAD
  * [az (Azure CLI)][azurecli] installed and aunthenticated
=======
  * [az (Azure CLI)][azurecli]
>>>>>>> 848cee28f... Moved install configs, manifests, and ignition configs out of scripts to docs
  * python3
  * [jq][jqjson]
  * [yq][yqyaml]
* python dotmap library: install it with `pip install dotmap`

## Setup

The machines will be started manually. Therefore, it is required to generate
the bootstrap and machine ignition configs and store them for later steps.

### Create Configuration

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

#### Extract Resource Group from Config

All resources created as part of this Azure deployment will exist as part of a
resource group. Export the resource group name from the generated configuration,
along with other environment variables that will be used in this example, with
the commands below.

```sh
export RESOURCE_GROUP_NAME=`yq -r .metadata.name install-config.yaml`
export AZURE_REGION=`yq -r .platform.azure.region install-config.yaml`
export VHD_URL="https://rhcos.blob.core.windows.net/imagebucket/"
export VHD_NAME="rhcos-42.80.20191002.0.vhd"
export SSH_KEY=`yq -r .sshKey install-config.yaml`
export BASE_DOMAIN=`yq -r .baseDomain install-config.yaml`
```

#### Create manifests

Create manifests to enable customizations which are not exposed via the install configuration.

```console
$ openshift-install create manifests
INFO Credentials loaded from file "/home/user_id/.azure/osServicePrincipal.json"
INFO Consuming "Install Config" from target directory
```

Run the script below to adjust the manifests to the unique resource group name to be used:

```sh
python3 setup-manifests.py $RESOURCE_GROUP_NAME
```

#### Remove control plane machines

Remove the control plane machines from the manifests.
We'll be providing those ourselves and don't want to involve [the machine-API operator][machine-api-operator].

```sh
rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml
```

#### Remove compute machinesets (Optional)

If you do not want the cluster to provision compute machines, remove the compute machinesets from the manifests as well.

```sh
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml
```

### Create Ignition Configs

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

### Create The Resource Group

All resources created as part of this Azure deployment will exist as part of a resource group. Use the commands
below to create it for the unique name set in the RESOURCE_GROUP_NAME and the region set in the AZREGION environment
variable.

```sh
az group create --name $RESOURCE_GROUP_NAME --location $AZURE_REGION
az identity create -g $RESOURCE_GROUP_NAME -n ${RESOURCE_GROUP_NAME}_userid
```

### Create a Storage Account

Create a storage account and export its key as an environment variable.

```sh
az storage account create --location $AZURE_REGION --name sa${RESOURCE_GROUP_NAME} --kind Storage --resource-group $RESOURCE_GROUP_NAME --sku Standard_LRS
export ACCOUNT_KEY=`az storage account keys list --account-name sa${RESOURCE_GROUP_NAME} --resource-group $RESOURCE_GROUP_NAME --query "[0].value" -o tsv`
```

### Copy the RHCOS Virtual Hard Disk (VHD)

Given the size of the Red Hat Enterprise Linux CoreOS virtual hard disk, it's not possible to run the required commands
with the VHD stored locally. We must copy and store it in the resource group instead. To do so:

```sh
az storage container create --name vhd --account-name sa${RESOURCE_GROUP_NAME}
az storage blob copy start --account-name sa${RESOURCE_GROUP_NAME} --account-key "$ACCOUNT_KEY" --destination-blob "rhcos.vhd" --destination-container vhd --source-uri "${VHD_URL}${VHD_NAME}"
```

To track the progress, you can use:

```sh
status="unknown"
while [ "$status" != "success" ]
do
    status=`az storage blob show --container-name vhd --name "rhcos.vhd" --account-name sa${RESOURCE_GROUP_NAME} --account-key $ACCOUNT_KEY -o tsv --query properties.copy.status`
done
```

### Configure the Template With Ignition Files

The key part of this UPI deployment is `azuredeploy.json`, an [Azure Resource Manager][azuretemplates] template responsible
for deploying most resources. The template exposes some of its configurations as deployment parameters in
`azuredeploy.parameters.json`. Use the following commands to configure the parameters based on the generated ignition files.

```sh
az storage container create --name files --account-name sa${RESOURCE_GROUP_NAME} --public-access blob
az storage blob upload --account-name sa${RESOURCE_GROUP_NAME} --account-key $ACCOUNT_KEY -c "files" -f "bootstrap.ign" -n "bootstrap.ign"
export BOOTSTRAPURL=`az storage blob url --account-name sa${RESOURCE_GROUP_NAME} --account-key $ACCOUNT_KEY -c "files" -n "bootstrap.ign" -o tsv`
python3 setup-variables.py $BOOTSTRAPURL sa${RESOURCE_GROUP_NAME} "${SSH_KEY}"
```

### Create public IP addresses

```sh
az network public-ip create -g $RESOURCE_GROUP_NAME -n $RESOURCE_GROUP_NAME --allocation-method static
az network public-ip create -g $RESOURCE_GROUP_NAME -n ${RESOURCE_GROUP_NAME}app --allocation-method static

export PUBLIC_IP=`az network public-ip list -g $RESOURCE_GROUP_NAME --query "[?name=='${RESOURCE_GROUP_NAME}'] | [0].ipAddress" -o tsv`
export PUBLIC_IP_APPS=`az network public-ip list -g $RESOURCE_GROUP_NAME --query "[?name=='${RESOURCE_GROUP_NAME}app'] | [0].ipAddress" -o tsv`
```

### DNS

```sh
az network private-dns zone create -g $RESOURCE_GROUP_NAME -n ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN}

az network private-dns record-set srv add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t bootstrap-0.${RESOURCE_GROUP_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t etcd-0.${RESOURCE_GROUP_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t etcd-1.${RESOURCE_GROUP_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 10 -w 10 -t etcd-2.${RESOURCE_GROUP_NAME}.${BASE_DOMAIN}

az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n bootstrap-0 -a 10.0.0.4
az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n control-plane-0 -a 10.0.0.5
az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n control-plane-1 -a 10.0.0.6
az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n control-plane-2 -a 10.0.0.7
az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n etcd-0 -a 10.0.0.5
az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n etcd-1 -a 10.0.0.6
az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n etcd-2 -a 10.0.0.7

az network private-dns record-set a create -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n api --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n api-int --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n *.apps --ttl 300
az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n api -a $PUBLIC_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n api-int -a $PUBLIC_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n *.apps -a $PUBLIC_IP_APPS

az network dns zone create -g $RESOURCE_GROUP_NAME -n ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN}

az network dns record-set a create -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n api --ttl 60
az network dns record-set a create -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n *.apps --ttl 300
az network dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n api -a $PUBLIC_IP
az network dns record-set a add-record -g $RESOURCE_GROUP_NAME -z ${RESOURCE_GROUP_NAME}.${BASE_DOMAIN} -n *.apps -a $PUBLIC_IP_APPS
```

## Deployment

Start the deployment:

```sh
az group deployment create \
   --name $RESOURCE_GROUP_NAME \
   --resource-group $RESOURCE_GROUP_NAME \
   --template-file "azuredeploy.json" \
   --parameters "runit.parameters.json"
```

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
az vm stop --resource-group $RESOURCE_GROUP_NAME --name bootstrap-0
az vm deallocate --resource-group $RESOURCE_GROUP_NAME --name bootstrap-0 --no-wait
az storage blob delete --account-key $ACCOUNT_KEY --account-name sa${RESOURCE_GROUP_NAME} --container-name files --name bootstrap.ign
```

## Customization

By default this creates:

* A Resource Group
* 3 Masters
* 3-16 Workers
* A API Loadbalancer
* A Application Loadbalancer
* 2 Availablity Groups

These can be changed by editing `azuredeploy.json`, `azuredeploy.parameters.json`, `master.json`, or `node.json`. The
OpenShift version to be deployed can be changed by pointing the VHD_NAME environment variable to a different RHCOS VHD
image. Note that 4.3 is the minimum version supported for Azure UPI.

[azuretemplates]: https://docs.microsoft.com/en-us/azure/azure-resource-manager/template-deployment-overview
[openshiftinstall]: https://github.com/openshift/installer
[azurecli]: https://docs.microsoft.com/en-us/cli/azure/
[jqjson]: https://stedolan.github.io/jq/
[yqyaml]: https://yq.readthedocs.io/en/latest/
