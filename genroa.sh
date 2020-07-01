#!/bin/bash

# generate signed RPKI route origin authorization(s)
#
# Perform the following tasks:
# - generate a signing key (store and retrieve from 1Password)
# - extract the public key (for one-time setup of ARIN hosted RPKI)
# - generate ROA(s) for listed networks and provided ORIGIN ASNs
# - sign and format ROAs for submission to ARIN's "Signed ROA Request"
#
# jlavoie@bowdoin.edu Tue Jun 30 17:08:33 EDT 2020

set -e

KEYPAIR="orgkeypair.pem"
PUBKEY="org_pubkey.cer"
NETS="nets.json"
ORG_ID="BOWDOI-1"
TIMESTAMP=$(date +%s)
START=$(date +%m-%d-%Y)
END=$(date -v+5y +%m-%d-%Y)

while getopts "n:" arg; do
  case "$arg" in
    n)
      name=$OPTARG
      ;;
    *)
      echo "Usage: $0 [-n <ROA name>] [ASN]..."
      exit 1
      ;;
  esac
done
shift $((OPTIND-1))

# use BOWDOIN ASN if unspecified
[ "$#" -eq 0 ] && set -- 22847

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

# extract public key
if [ ! -s "$PUBKEY" ] ; then
  echo "Extracting public key $PUBKEY from keypair $KEYPAIR"
  openssl rsa -in "$KEYPAIR" -pubout -outform PEM -out "$PUBKEY"
  echo "Please add the following to the ARIN hosted RPKI interface for $ORG_ID"
  cat "$PUBKEY"
fi

# generate and sign ROAs
for asn; do
  if ! [[ "$asn" -ge 0 && "$asn" -le 4294967295 ]]; then
    echo
    echo "Skipping invalid ASN $asn"
    continue
  fi
  roa=''
  for net in $(jq -c '.[]' "$NETS") ; do
    prefix=$(jq -r .prefix <<<"$net" | tr a-f A-F)
    length=$(jq -r .length <<<"$net")
    maxlength=$(jq -r '.maxlength // .length' <<<"$net")
    roaname="BOWDOIN${name:+-$name-$asn}"
    if [ -z "$roa" ] ; then
      roa="1|$TIMESTAMP|$roaname|$asn|$START|$END|$prefix|$length|$maxlength|"
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
