#!/bin/sh
# Signs the SAML fixtures with xmlsec1 (an independent XML-DSig
# implementation), so authmk's verifier is checked against it, not itself.
# Rerun after changing a template: ./generate.sh (needs openssl, xmlsec1).
set -e
cd "$(dirname "$0")"

openssl req -x509 -newkey rsa:2048 -nodes -keyout idp-rsa.key -out idp-rsa.crt \
  -days 36500 -subj "/CN=Test IdP RSA" 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout idp-ec.key \
  -out idp-ec.crt -days 36500 -subj "/CN=Test IdP EC" 2>/dev/null

sign() {
  # $1 template, $2 key, $3 cert, $4 output, $5 element to sign
  xmlsec1 --sign --privkey-pem "$2,$3" \
    --id-attr:ID "urn:oasis:names:tc:SAML:2.0:$5" \
    --output "$4" "$1"
}

sign response.template.xml idp-rsa.key idp-rsa.crt response-rsa.xml assertion:Assertion
sed -e 's/rsa-sha256/ecdsa-sha256/' response.template.xml > /tmp/authmk-ec.template.xml
sign /tmp/authmk-ec.template.xml idp-ec.key idp-ec.crt response-ec.xml assertion:Assertion
sign response-prefixlist.template.xml idp-rsa.key idp-rsa.crt response-prefixlist.xml assertion:Assertion
sign response-signed.template.xml idp-rsa.key idp-rsa.crt response-signed.xml protocol:Response
rm -f /tmp/authmk-ec.template.xml

# The service provider's (authmk's) key for signing AuthnRequests.
openssl req -x509 -newkey rsa:2048 -nodes -keyout sp-rsa.key -out sp-rsa.crt \
  -days 36500 -subj "/CN=Test SP" 2>/dev/null

# Canonicalization test vectors, from libxml2.
xmllint --exc-c14n c14n-input.xml > c14n-expected.xml

# Encrypted assertions (for the SP's key): AES-256-GCM, and AES-256-CBC.
python3 - <<'PY'
import re
s = open("response-rsa.xml").read()
s = re.sub(r"(<saml:Assertion .*?</saml:Assertion>)", r"<saml:EncryptedAssertion>\1</saml:EncryptedAssertion>", s, flags=re.S)
open("/tmp/authmk-wrapped.xml", "w").write(s)
PY
for mode in gcm cbc; do
  case $mode in
    gcm) alg="http://www.w3.org/2009/xmlenc11#aes256-gcm" ;;
    cbc) alg="http://www.w3.org/2001/04/xmlenc#aes256-cbc" ;;
  esac
  cat > /tmp/authmk-enc-template.xml <<TPL
<xenc:EncryptedData xmlns:xenc="http://www.w3.org/2001/04/xmlenc#" Type="http://www.w3.org/2001/04/xmlenc#Element"><xenc:EncryptionMethod Algorithm="$alg"/><ds:KeyInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><xenc:EncryptedKey><xenc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#rsa-oaep-mgf1p"><ds:DigestMethod Algorithm="http://www.w3.org/2000/09/xmldsig#sha1"/></xenc:EncryptionMethod><xenc:CipherData><xenc:CipherValue/></xenc:CipherData></xenc:EncryptedKey></ds:KeyInfo><xenc:CipherData><xenc:CipherValue/></xenc:CipherData></xenc:EncryptedData>
TPL
  xmlsec1 --encrypt --pubkey-cert-pem sp-rsa.crt --session-key aes-256 \
    --xml-data /tmp/authmk-wrapped.xml --node-xpath "//*[local-name()='Assertion']" \
    --output "response-encrypted-$mode.xml" /tmp/authmk-enc-template.xml
done
rm -f /tmp/authmk-wrapped.xml /tmp/authmk-enc-template.xml
