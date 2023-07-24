#!/usr/bin/env bash

function assert_env_var_exists() {
  if [[ -z "${!1}" ]]; then
    echo "ERROR - Missing or empty $1 environment variable"
  fi
}

assert_env_var_exists "SUBSCRIPTION_ID"
assert_env_var_exists "RESOURCE_GROUP"
assert_env_var_exists "LOCATION"
assert_env_var_exists "STORAGE_ACCOUNT"
assert_env_var_exists "IMAGE_TYPE"

subscription_id=$SUBSCRIPTION_ID
resource_group=$RESOURCE_GROUP
location=$LOCATION
storage_account=$STORAGE_ACCOUNT
service_principal_name="${resource_group}-packer"
image_type=${IMAGE_TYPE}

image_os=

if [[ $image_type == windows* ]]; then
  image_os="win"
  filename="${image_type}.json"
elif [[ $image_type == ubuntu* ]]; then
  image_os="linux"
  filename="${image_type}.pkr.hcl"
else
  echo "ERROR - IMAGE_TYPE must start with 'windows' or 'ubuntu'."
  exit 1
fi

echo "=> Creating resources for build"

echo "=> [+] Creating storage account: ${storage_account}"

az storage account create \
  --name $storage_account \
  --resource-group $resource_group \
  --location $location \
  --sku Standard_LRS \
  --allow-blob-public-access true \
  --only-show-errors \
  --output none

if [[ -z $CLIENT_ID && -z $CLIENT_SECRET && -z $TENANT_ID ]]; then
  echo "=> [+] Creating service principal: ${service_principal_name}"

  service_principal=$(
    az ad sp create-for-rbac \
      --name ${service_principal_name} \
      --role Contributor \
      --scopes /subscriptions/$subscription_id \
      --query "{ client_id: appId, client_secret: password, tenant_id: tenant }" \
      --only-show-errors
  )

  client_id=$(echo $service_principal | jq -r .client_id)
  client_secret=$(echo $service_principal | jq -r .client_secret)
  tenant_id=$(echo $service_principal | jq -r .tenant_id)

  if [[ -z $client_id || -z $client_secret || -z $tenant_id ]]; then
    echo "ERROR - Service principal could not be created"
    exit 1
  fi
else
  assert_env_var_exists "CLIENT_ID"
  assert_env_var_exists "CLIENT_SECRET"
  assert_env_var_exists "TENANT_ID"

  client_id=$CLIENT_ID
  client_secret=$CLIENT_SECRET
  tenant_id=$TENANT_ID
fi

# We have to wait or the service principal
# may not be ready for Packer to start
sleep 30

echo "=> [+] Created storage account: ${storage_account}"
echo "=> [+] Created service principal: ${service_principal_name} (${client_id})"

echo "=> Finished creating resources"
echo "=> Starting Packer build"

packer build \
  -var client_id=${client_id} \
  -var client_secret=${client_secret} \
  -var subscription_id=${subscription_id} \
  -var tenant_id=${tenant_id} \
  -var location=${location} \
  -var resource_group=${resource_group} \
  -var storage_account=${storage_account} \
  -var capture_name_prefix=${image_type} \
  images/${image_os}/${filename}

echo "=> Cleaning up"

echo "=> [-] Removing service principal"

az ad sp delete --id $client_id

echo "=> [-] Removing app registration"

az ad app delete --id $client_id
