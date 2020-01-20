#!/bin/sh
set -e

openshift-install create install-config

export CLUSTER_NAME=`yq -r .metadata.name install-config.yaml`
export AZURE_REGION=`yq -r .platform.azure.region install-config.yaml`
export SSH_KEY=`yq -r .sshKey install-config.yaml | xargs`
export BASE_DOMAIN=`yq -r .baseDomain install-config.yaml`
export RESOURCE_GROUP=$CLUSTER_NAME

read -p "pause"

python -c '
import yaml;
path = "install-config.yaml";
data = yaml.full_load(open(path));
data["compute"][0]["replicas"] = 0;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'

openshift-install create manifests

python3 setup-manifests.py $RESOURCE_GROUP

rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml

python -c '
import yaml;
path = "manifests/cluster-scheduler-02-config.yml"
data = yaml.load(open(path), Loader=yaml.BaseLoader);
data["spec"]["mastersSchedulable"] = False;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'

# cat > manifests/ingress-controller-02-default.yaml <<EOF
# apiVersion: operator.openshift.io/v1
# kind: IngressController
# metadata:
#   finalizers:
#   - ingresscontroller.operator.openshift.io/finalizer-ingresscontroller
#   name: default
#   namespace: openshift-ingress-operator
# spec:
#   endpointPublishingStrategy:
#     type: HostNetwork
#   replicas: 3
# EOF

openshift-install create ignition-configs

export INFRA_ID=$(jq -r .infraID metadata.json)
echo "Infra ID is ${INFRA_ID}"

az group create --name $RESOURCE_GROUP --location $AZURE_REGION
az identity create -g $RESOURCE_GROUP -n ${RESOURCE_GROUP}-identity

az storage account create -g $RESOURCE_GROUP --location $AZURE_REGION --name ${CLUSTER_NAME}sa --kind Storage --sku Standard_LRS
export ACCOUNT_KEY=`az storage account keys list -g $RESOURCE_GROUP --account-name ${CLUSTER_NAME}sa --query "[0].value" -o tsv`

# export VHD_URL="https://rhcos.blob.core.windows.net/imagebucket/rhcos-42.80.20191002.0.vhd"
export VHD_URL="https://rhcos.blob.core.windows.net/imagebucket/rhcos-43.81.202001142154.0-azure.x86_64.vhd"
# export VHD_URL=`curl -s https://raw.githubusercontent.com/openshift/installer/master/data/data/rhcos.json | jq -r .azure.url`

az storage container create --name vhd --account-name ${CLUSTER_NAME}sa
az storage blob copy start --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY --destination-blob "rhcos.vhd" --destination-container vhd --source-uri "$VHD_URL"
status="unknown"
while [ "$status" != "success" ]
do
  status=`az storage blob show --container-name vhd --name "rhcos.vhd" --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -o tsv --query properties.copy.status`
  echo $status
done

az storage container create --name files --account-name ${CLUSTER_NAME}sa --public-access blob
az storage blob upload --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c "files" -f "bootstrap.ign" -n "bootstrap.ign"
export BOOTSTRAP_URL=`az storage blob url --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c "files" -n "bootstrap.ign" -o tsv`

az network private-dns zone create -g $RESOURCE_GROUP -n ${CLUSTER_NAME}.${BASE_DOMAIN}

export PRINCIPAL_ID=`az identity show -g $RESOURCE_GROUP -n ${RESOURCE_GROUP}-identity --query principalId --out tsv`
export RESOURCE_GROUP_ID=`az group show -g $RESOURCE_GROUP --query id --out tsv`
az role assignment create --assignee "$PRINCIPAL_ID" --role 'Contributor' --scope "$RESOURCE_GROUP_ID"

az group deployment create -g $RESOURCE_GROUP \
  --template-file "01_vpc.json"

az network private-dns link vnet create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n ${CLUSTER_NAME}-network-link -v "${RESOURCE_GROUP}-vnet" -e false

export VHD_BLOB_URL=`az storage blob url --account-name ${CLUSTER_NAME}sa --account-key $ACCOUNT_KEY -c vhd -n "rhcos.vhd" -o tsv`

az group deployment create -g $RESOURCE_GROUP \
  --template-file "02_storage.json" \
  --parameters vhdBlobURL="${VHD_BLOB_URL}"

az group deployment create -g $RESOURCE_GROUP \
  --template-file "03_infra.json"

export PUBLIC_IP=`az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${CLUSTER_NAME}-master-pip'] | [0].ipAddress" -o tsv`

echo
echo "Public IP: ${PUBLIC_IP}"

read -p "Create the public DNS entries then press [ENTER] to continue..."
# az network dns record-set a create -g os4-common -z ${BASE_DOMAIN} -n "api.${CLUSTER_NAME}" --ttl 60
# az network dns record-set a add-record -g os4-common -z ${BASE_DOMAIN} -n "api.${CLUSTER_NAME}" -a $PUBLIC_IP --ttl 60

export INTERNAL_LB_IP=`az network lb frontend-ip show -g $RESOURCE_GROUP --lb-name ${RESOURCE_GROUP}-internal-lb -n internal-lb-ip --query "privateIpAddress" -o tsv`

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api-int --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api -a $INTERNAL_LB_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n api-int -a $INTERNAL_LB_IP

export BOOTSTRAP_IGNITION=`python3 setup-bootstrap-ignition.py $BOOTSTRAP_URL`

az group deployment create -g $RESOURCE_GROUP \
  --template-file "04_bootstrap.json" \
  --parameters bootstrapIgnition="$BOOTSTRAP_IGNITION" \
  --parameters sshKeyData="$SSH_KEY"

export BOOTSTRAP_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-bootstrap-nic -n pipConfig --query "privateIpAddress" -o tsv`

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n bootstrap-0 --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n bootstrap-0 -a $BOOTSTRAP_IP

az network private-dns record-set srv create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp --ttl 60

az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 0 -w 10 -t bootstrap-0.${CLUSTER_NAME}.${BASE_DOMAIN}

export MASTER_IGNITION=`cat master.ign | base64`

az group deployment create -g $RESOURCE_GROUP \
  --template-file "05_masters.json" \
  --parameters masterIgnition="$MASTER_IGNITION" \
  --parameters sshKeyData="$SSH_KEY"

export MASTER0_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-master-0-nic -n pipConfig --query "privateIpAddress" -o tsv`
export MASTER1_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-master-1-nic -n pipConfig --query "privateIpAddress" -o tsv`
export MASTER2_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-master-2-nic -n pipConfig --query "privateIpAddress" -o tsv`

az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-0 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-1 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-2 --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-0 -a $MASTER0_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-1 -a $MASTER1_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n etcd-2 -a $MASTER2_IP

az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 0 -w 10 -t etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 0 -w 10 -t etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}
az network private-dns record-set srv add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n _etcd-server-ssl._tcp -r 2380 -p 0 -w 10 -t etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}

openshift-install wait-for bootstrap-complete --log-level debug

az vm stop -g $RESOURCE_GROUP --name ${RESOURCE_GROUP}-bootstrap
az vm deallocate -g $RESOURCE_GROUP --name ${RESOURCE_GROUP}-bootstrap --no-wait
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
# sleep 600
# oc get csr -o name | xargs oc adm certificate approve
# sleep 600
# oc get csr -o name | xargs oc adm certificate approve

export NODE1_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-worker-centralus-1-nic -n pipConfig --query "privateIpAddress" -o tsv`
export NODE2_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-worker-centralus-2-nic -n pipConfig --query "privateIpAddress" -o tsv`
export NODE3_IP=`az network nic ip-config show -g $RESOURCE_GROUP --nic-name ${RESOURCE_GROUP}-worker-centralus-3-nic -n pipConfig --query "privateIpAddress" -o tsv`
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n node01 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n node02 --ttl 60
az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n node03 --ttl 60
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n node01 -a $NODE1_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n node02 -a $NODE2_IP
az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n node03 -a $NODE3_IP

oc -n openshift-ingress get service router-default

# export PUBLIC_IP_INFRA=`az network public-ip list -g $RESOURCE_GROUP --query "[?name=='${CLUSTER_NAME}-infra-pip'] | [0].ipAddress" -o tsv`
export PUBLIC_IP_ROUTER=`oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}'`

echo
# echo "Public infra IP: ${PUBLIC_IP_INFRA}"
echo "Public router IP: ${PUBLIC_IP_ROUTER}"

echo
read -p "Waint until the IP for the public router is available, create the DNS entries for it then press [ENTER] to continue..."

# az network dns record-set a create -g os4-common -z ${BASE_DOMAIN} -n "*.apps.${CLUSTER_NAME}" --ttl 30
# az network dns record-set a add-record -g os4-common -z ${BASE_DOMAIN} -n "*.apps.${CLUSTER_NAME}" -a $PUBLIC_IP_ROUTER --ttl 30

# az network private-dns record-set a create -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps --ttl 30
# az network private-dns record-set a add-record -g $RESOURCE_GROUP -z ${CLUSTER_NAME}.${BASE_DOMAIN} -n *.apps -a $PUBLIC_IP_ROUTER

openshift-install wait-for install-complete --log-level debug
