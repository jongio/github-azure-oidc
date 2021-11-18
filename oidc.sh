#!/bin/bash
set -euo pipefail

# Install Azure CLI
# Install GitHub CLI

# ./oidc.sh {APP_NAME} {ORG|USER/REPO}
# ./oidc.sh appname1 jongio/ghazoidctest1
IS_CODESPACE=${CODESPACES:-"false"}
if $IS_CODESPACE == "true"; then
    echo "This script doesn't work in GitHub Codespaces.  See this issue for updates. https://github.com/Azure/login/issues/177"
    exit 0
fi

APP_NAME=$1
REPO=$2

echo "Checking Azure CLI login status..."
EXPIRED_TOKEN=$(az ad signed-in-user show --query 'objectId' -o tsv || true)

if [[ -z "$EXPIRED_TOKEN" ]]; then
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
        echo "Use the \`az account set\` command to set the subscription you'd like to use and re-run this script."
        exit 0
        ;;
esac

echo "Logging into GitHub CLI..."
gh auth login

echo "Getting Subscription Id..."
SUB_ID=$(az account show --query id -o tsv)
echo "SUB_ID: $SUB_ID"

echo "Getting Tenant Id..."
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "TENANT_ID: $TENANT_ID"

echo "Configuring application..."
#  First check if an app with the same name exists, if so use it, if not create one
APP_ID=$(az ad app list --display-name ${APP_NAME} --query "[?displayName=='${APP_NAME}']".appId -o tsv)

if [[ -z "$APP_ID" ]]; then
    echo "Creating AD app..."
    APP_ID=$(az ad app create --display-name ${APP_NAME} --query appId -o tsv)
else
    echo "Existing AD app found."
fi

echo "APP_ID: $APP_ID"

echo "Getting AD App objectId, which is the same as the service principals appId..."

APP_OBJECT_ID=$(az ad app show --id $APP_ID --query objectId -o tsv)
echo "APP_OBJECT_ID: $APP_OBJECT_ID"

echo "Configuring Service Principal..."

SP_OBJECT_ID=$(az ad sp show --id $APP_ID --query appId -o tsv || true)
if [[ -z "$SP_OBJECT_ID" ]]; then
    echo "Creating service principal..."
    SP_OBJECT_ID=$(az ad sp create --id $APP_ID --query objectId -o tsv)

    echo "Sleeping for 30 seconds to give time for the SP to be created."
    sleep 30s

    echo "Creating role assignment..."
    az role assignment create --role contributor --subscription $SUB_ID --assignee-object-id $SP_OBJECT_ID --assignee-principal-type ServicePrincipal
else
    echo "Existing Service Principal found."
fi

echo "SP_OBJECT_ID: $SP_OBJECT_ID"

echo "Creating federatedIdentityCredentials..."
az rest --method POST --uri "https://graph.microsoft.com/beta/applications/${APP_OBJECT_ID}/federatedIdentityCredentials" --body "{'name':'prfic','issuer':'https://token.actions.githubusercontent.com','subject':'repo:${REPO}:pull-request','description':'pr','audiences':['api://AzureADTokenExchange']}"
az rest --method POST --uri "https://graph.microsoft.com/beta/applications/${APP_OBJECT_ID}/federatedIdentityCredentials" --body "{'name':'mainfic','issuer':'https://token.actions.githubusercontent.com','subject':'repo:${REPO}:ref:refs/heads/main','description':'main','audiences':['api://AzureADTokenExchange']}"
# To get an Azure AD app FICs
#az rest --method GET --uri "https://graph.microsoft.com/beta/applications/${APP_OBJECT_ID}/federatedIdentityCredentials"
# To delete an Azure AD app FIC
#az rest --method DELETE --uri "https://graph.microsoft.com/beta/applications/${APP_OBJECT_ID}/federatedIdentityCredentials/${FIC_ID}"
# You can also delete FICs here: 
# https://ms.portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Credentials/appId/${APP_ID}/isMSAApp/

echo "Creating the following GitHub repo secrets..."
echo AZURE_CLIENT_ID=$APP_ID
echo AZURE_SUBSCRIPTION_ID=$SUB_ID
echo AZURE_TENANT_ID=$TENANT_ID

gh secret set AZURE_CLIENT_ID -b${APP_ID}
gh secret set AZURE_SUBSCRIPTION_ID -b${SUB_ID}
gh secret set AZURE_TENANT_ID -b${TENANT_ID}