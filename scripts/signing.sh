#!/bin/bash
# Shared signing helpers, sourced by make-app.sh and make-dmg.sh.
#
#   SIGN_IDENTITY   override the identity ("-" forces ad-hoc signing)
#   NOTARY_PROFILE  notarytool keychain profile (default: OpenMacStorage-notary)

# Picks the first "Developer ID Application" identity in the keychain, or
# "-" (ad-hoc) when there is none — e.g. contributors building from source.
signing_identity() {
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "$SIGN_IDENTITY"
    return
  fi
  local id
  id=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 '"Developer ID Application' \
        | sed -E 's/.*"(.*)"/\1/') || true
  echo "${id:--}"
}

NOTARY_PROFILE="${NOTARY_PROFILE:-OpenMacStorage-notary}"
