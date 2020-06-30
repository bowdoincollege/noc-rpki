#!/bin/bash

set -e

ORG_ID="BOWDOI-1"
TIMESTAMP=$(date +%s)
START=$(date +%m-%d-%Y)
END=$(date -v+5y +%m-%d-%Y)
ORIGIN_AS=(22847)
KEYPAIR="orgkeypair.pem"
PUBKEY="org_pubkey.cer"
NETS="nets.json"

# generate RPKI signing key
if [ -s "$KEYPAIR" ]; then
  echo "Using existing $KEYPAIR key file."
else
  if ! op get account >/dev/null 2>&1 ; then
    echo "Please sign in to 1Password to retrieve private key."
    if ! SESSION=$(op signin bowdoin) ; then
      echo "1Password login failed, exiting."
      exit 2
    fi
    eval "$SESSION"
  fi
  TITLE="ARIN RPKI key pair"
  echo "Retrieving $KEYPAIR from 1Password as $TITLE document."
  if ! op get document "$TITLE" --output "$KEYPAIR" --vault Networking; then
    echo "Keyfile not found in 1Password, generating new private key $KEYPAIR"
    openssl genrsa -out "$KEYPAIR" 2048
    echo "Uploading $KEYPAIR to 1Password as $TITLE document."
    op create document "$KEYPAIR" --title "$TITLE" --vault Networking
  fi
fi

if [ ! -s "$PUBKEY" ] ; then
  echo "Extracting public key $PUBKEY from keypair $KEYPAIR"
  openssl rsa -in "$KEYPAIR" -pubout -outform PEM -out "$PUBKEY"
  echo "Please add the following to the ARIN hosted RPKI interface for $ORG_ID"
  cat "$PUBKEY"
fi

# generate and sign ROAs
for as in "${ORIGIN_AS[@]}" ; do
  roa=''
  for net in $(jq -c '.[]' "$NETS") ; do
    prefix=$(jq -r .prefix <<<"$net" | tr a-f A-F)
    length=$(jq -r .length <<<"$net")
    maxlength=$(jq -r .maxlength <<<"$net")
    if [ -z "$roa" ] ; then
      roa="1|$TIMESTAMP|BOWDOIN|$as|$START|$END|$prefix|$length|$maxlength|"
    else
      roa="$roa$prefix|$length|$maxlength|"
    fi
  done

  signature=$(openssl dgst -sha256 -sign "$KEYPAIR" \
    -keyform PEM <(echo -n "$roa") \
    | openssl enc -base64)

  echo
  echo "Please add the following ROA to ARIN's \"create ROA\" interface."
  cat <<-EOF | sed 's/^ *//'
     -----BEGIN ROA REQUEST-----
     $roa
     -----END ROA REQUEST-----
     -----BEGIN SIGNATURE-----
     $signature
     -----END SIGNATURE-----
EOF
done
