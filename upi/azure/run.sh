#!/bin/sh
set -e

openshift-install create install-config

export CLUSTER_NAME=`yq -r .metadata.name install-config.yaml`
export AZURE_REGION=`yq -r .platform.azure.region install-config.yaml`
export SSH_KEY=`yq -r .sshKey install-config.yaml | xargs`
export BASE_DOMAIN=`yq -r .baseDomain install-config.yaml`
export BASE_DOMAIN_RESOURCE_GROUP=`yq -r .platform.azure.baseDomainResourceGroupName install-config.yaml`
export RESOURCE_GROUP=$CLUSTER_NAME

python3 -c '
import yaml;
path = "install-config.yaml";
data = yaml.full_load(open(path));
data["compute"][0]["replicas"] = 0;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'

openshift-install create manifests

python3 setup-manifests.py $RESOURCE_GROUP

rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml

openshift-install create ignition-configs

export INFRA_ID=$(jq -r .infraID metadata.json)
echo "Infra ID is ${INFRA_ID}"

az group create --name $RESOURCE_GROUP --location $AZURE_REGION
az identity create -g $RESOURCE_GROUP -n ${RESOURCE_GROUP}-identity

az storage account create -g $RESOURCE_GROUP --location $AZURE_REGION --name ${CLUSTER_NAME}sa --kind Storage --sku Standard_LRS
export ACCOUNT_KEY=`az storage account keys list -g $RESOURCE_GROUP --account-name ${CLUSTER_NAME}sa --query "[0].value" -o tsv`

export VHD_URL=`curl -s https://raw.githubusercontent.com/openshift/installer/release-4.3/data/data/rhcos.json | jq -r .azure.url`

az storage container create --name vhd --account-name ${CLUSTER_NAME}sa
az storage blob copy start --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY --destination-blob "rhcos.vhd" --destination-container vhd --source-uri "$VHD_URL"
status="unknown"
while [ "$status" != "success" ]
do
  status=`az storage blob show --container-name vhd --name "rhcos.vhd" --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -o tsv --query properties.copy.status`
  echo $status
done

export VHD_BLOB_URL=`az storage blob url --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c vhd -n "rhcos.vhd" -o tsv`

az storage container create --name files --account-name ${CLUSTER_NAME}sa --public-access blob
az storage blob upload --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c "files" -f "bootstrap.ign" -n "bootstrap.ign"

export BOOTSTRAP_URL=`az storage blob url --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c "files" -n "bootstrap.ign" -o tsv`

az network private-dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}

export PRINCIPAL_ID=`az identity show -g $RESOURCE_GROUP -n ${RESOURCE_GROUP}-identity --query principalId --out tsv`
export RESOURCE_GROUP_ID=`az group show -g $RESOURCE_GROUP --query id --out tsv`
az role assignment create --assignee "$PRINCIPAL_ID" --role 'Contributor' --scope "$RESOURCE_GROUP_ID"

az group deployment create -g $RESOURCE_GROUP \
  --template-file "01_vnet.json"

az network private-dns link vnet create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n ${CLUSTER_NAME}-network-link -v "${RESOURCE_GROUP}-vnet" -e false

az group deployment create -g $RESOURCE_GROUP \
  --template-file "02_storage.json" \
  --parameters vhdBlobURL="${VHD_BLOB_URL}"

az group deployment create -g $RESOURCE_GROUP \
  --template-file "03_infra.json" \
  --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}"

export PUBLIC_IP=`az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${CLUSTER_NAME}-master-pip'] | [0].ipAddress" -o tsv`
echo "API public IP: ${PUBLIC_IP}"
az network dns record-set a add-record -g $BASE_DOMAIN_RESOURCE_GROUP -z ${BASE_DOMAIN} -n api.${CLUSTER_NAME} -a $PUBLIC_IP --ttl 60

export BOOTSTRAP_IGNITION=`python3 setup-bootstrap-ignition.py $BOOTSTRAP_URL`

az group deployment create -g $RESOURCE_GROUP \
  --template-file "04_bootstrap.json" \
  --parameters bootstrapIgnition="$BOOTSTRAP_IGNITION" \
  --parameters sshKeyData="$SSH_KEY" \
  --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}"

export MASTER_IGNITION=`cat master.ign | base64`

az group deployment create -g $RESOURCE_GROUP \
  --template-file "05_masters.json" \
  --parameters masterIgnition="$MASTER_IGNITION" \
  --parameters sshKeyData="$SSH_KEY" \
  --parameters privateDNSZoneName="${CLUSTER_NAME}.${BASE_DOMAIN}"

openshift-install wait-for bootstrap-complete --log-level debug

az vm stop -g $RESOURCE_GROUP --name ${RESOURCE_GROUP}-bootstrap
az vm deallocate -g $RESOURCE_GROUP --name ${RESOURCE_GROUP}-bootstrap
az vm delete -g $RESOURCE_GROUP --name ${RESOURCE_GROUP}-bootstrap --yes
az disk delete -g $RESOURCE_GROUP --name ${RESOURCE_GROUP}-bootstrap_OSDisk --no-wait --yes
az network nic delete -g $RESOURCE_GROUP --name ${RESOURCE_GROUP}-bootstrap-nic --no-wait
az storage blob delete --account-key $ACCOUNT_KEY --account-name ${CLUSTER_NAME}sa --container-name files --name bootstrap.ign

export KUBECONFIG="$PWD/auth/kubeconfig"
oc get nodes
oc get clusteroperator

export WORKER_IGNITION=`cat worker.ign | base64`

az group deployment create -g $RESOURCE_GROUP \
  --template-file "06_workers.json" \
  --parameters workerIgnition="$WORKER_IGNITION" \
  --parameters sshKeyData="$SSH_KEY"

oc get csr -A

echo
read -p "Approve the certificate signing requests (CSRs) then press [ENTER] to continue..."

status="<pending>"
while [[ $status =~ "pending" ]]
do
  status=`oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}'`
  echo $status
done

export PUBLIC_IP_ROUTER=`oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}'`
az network dns record-set a add-record -g $BASE_DOMAIN_RESOURCE_GROUP -z ${BASE_DOMAIN} -n *.apps.${CLUSTER_NAME} -a $PUBLIC_IP_ROUTER --ttl 300

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps --ttl 300
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps -a $PUBLIC_IP_ROUTER

openshift-install wait-for install-complete --log-level debug