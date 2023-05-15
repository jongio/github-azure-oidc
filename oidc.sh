#!/bin/bash
set -euo pipefail

# Open in DevContainer or...

    # Install Azure CLI- https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
    # Install GitHub CLI - https://cli.github.com/
    # Install JQ - https://stedolan.github.io/jq/download/

# ./oidc.sh {APP_NAME} {ORG|USER/REPO} {FICS_FILE}
# ./oidc.sh ghazoidc1 jongio/ghazoidctest ./fics.json
IS_CODESPACE=${CODESPACES:-"false"}
if $IS_CODESPACE == "true"
then
    echo "This script doesn't work in GitHub Codespaces.  See this issue for updates. https://github.com/Azure/azure-cli/issues/21025 "
    exit 0
fi

APP_NAME=$1
export REPO=$2
FICS_FILE=$3

echo "Checking Azure CLI login status..."
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'id' -o tsv || true)

if [[ -z "$EXPIRED_TOKEN" ]]
then
    az login -o none
fi

ACCOUNT=$(az account show --query '[id,name]')
echo $ACCOUNT

read -r -p "Do you want to use the above subscription? (Y/n) " response
response=${response:-Y}
case "$response" in
    [yY][eE][sS]|[yY]) 
        ;;
    *)
        echo "Use the \`az account set -s\` command to set the subscription you'd like to use and re-run this script."
        exit 0
        ;;
esac

echo "Getting Subscription Id..."
SUB_ID=$(az account show --query id -o tsv)
echo "SUB_ID: $SUB_ID"

echo "Getting Tenant Id..."
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "TENANT_ID: $TENANT_ID"

echo "Configuring application..."

#  First check if an app with the same name exists, if so use it, if not create one
APP_ID=$(az ad app list --filter "displayName eq '$APP_NAME'" --query [].appId -o tsv)

if [[ -z "$APP_ID" ]]
then
    echo "Creating AD app..."
    APP_ID=$(az ad app create --display-name ${APP_NAME} --query appId -o tsv)
    echo "Sleeping for 30 seconds to give time for the APP to be created."
    sleep 30s
else
    echo "Existing AD app found."
fi

echo "APP_ID: $APP_ID"

echo "Configuring Service Principal..."

echo "First checking if the Service Principal already exists..."
SP_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query [].id -o tsv)
if [[ -z "$SP_ID" ]]
then
    echo "Creating service principal..."
    SP_ID=$(az ad sp create --id $APP_ID --query id -o tsv)

    echo "Sleeping for 30 seconds to give time for the SP to be created."
    sleep 30s

    echo "Creating role assignment..."
    az role assignment create --role contributor --subscription $SUB_ID --assignee-object-id $SP_ID --assignee-principal-type ServicePrincipal
    sleep 30s
else
    echo "Existing Service Principal found."
fi

echo "SP_ID: $SP_ID"

echo "Creating Federated Identity Credentials..."
echo 
for FIC in $(envsubst < $FICS_FILE | jq -c '.[]'); do
    SUBJECT=$(jq -r '.subject' <<< "$FIC")
    
    echo "Creating FIC with subject '${SUBJECT}'."
    az ad app federated-credential create --id  $APP_ID --parameters ${FIC} || true
done

# To get an Azure AD app FICs
# az ad app federated-credential list --id $APP_ID

# To delete an Azure AD app FIC
# az ad app federated-credential list --id $APP_ID --federated-credential-id ${FIC_ID}

# You can view your FICs in the portal here:
# https://portal.azure.com/#view/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview/menuId~/null and search for the service principal ID
# https://ms.portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/${APP_ID}
# Certificates & secrets, Click on Federated credentials

echo "Creating the following GitHub repo secrets..."
echo AZURE_CLIENT_ID=$APP_ID
echo AZURE_SUBSCRIPTION_ID=$SUB_ID
echo AZURE_TENANT_ID=$TENANT_ID

echo "Logging into GitHub CLI..."
gh auth login

gh secret set AZURE_CLIENT_ID -b${APP_ID} --repo $REPO
gh secret set AZURE_SUBSCRIPTION_ID -b${SUB_ID} --repo $REPO
gh secret set AZURE_TENANT_ID -b${TENANT_ID} --repo $REPO
