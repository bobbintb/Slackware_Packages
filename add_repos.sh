#!/bin/bash

CONF="/etc/slackpkg/slackpkgplus.conf"
SLAKFINDER="https://slackware.nl/slakfinder/showrepo.php"
REPOPLUS="slackpkgplus"

[[ $# -eq 0 ]] && echo "Error: no repositories specified" && exit 1

# Fetch repo list
declare -A REPO_IDS
while IFS=$'\t' read -r id brief version; do
  [[ -n "$brief" ]] && REPO_IDS["${brief,,} $version"]="$id"
done < <(curl -s "$SLAKFINDER" | grep '<tr ><td' \
  | sed 's|.*<td >\([^<]*\)</td><td ><[^>]*>\([^<]*\)</a></td><td >\([^<]*\)</td><td >\([^<]*\)</td><td >\([^<]*\)<br>.*|\1\t\2\t\3\t\4\t\5|' \
  | awk -F'\t' '$3=="x86_64" && ($4=="current" || $4=="15.0") {print $1"\t"$2"\t"$4}')

# Match repos and build REPOPLUS
declare -A MIRRORPLUS
declare -A ENABLED_REPOS
for name in "$@"; do
  brief="${name%-*}"; key="${brief//_/ } ${name##*-}"; key="${key,,}"
  if [[ "$key" == "bobbintb"* ]]; then
    REPOPLUS+=" bobbintb"
    ENABLED_REPOS["bobbintb"]=1
    echo "Enabled: bobbintb"
  elif [[ -n "${REPO_IDS[$key]}" ]]; then
    ck="${key// /-}"; REPOPLUS+=" $ck"
    ENABLED_REPOS["$ck"]=1
    echo "Enabled: $ck"
  else
    echo "Warning: repo '$name' not found, skipping"
  fi
done

# Fetch all MIRRORPLUS URLs
for key in "${!REPO_IDS[@]}"; do
  MIRRORPLUS["${key// /-}"]=$(curl -s "$SLAKFINDER?repo=${REPO_IDS[$key]}" \
    | grep -A1 "<td >URL</td>" | sed -n "s|.*href='\([^']*\)'.*|\1|p")
done
MIRRORPLUS["bobbintb"]="https://bobbintb.github.io/Slackware_Packages/builds/"

# Write config
if grep -q "^REPOPLUS=" "$CONF"; then
  sed -i "s|^REPOPLUS=.*|REPOPLUS=( $REPOPLUS )|" "$CONF"
else
  echo "REPOPLUS=( $REPOPLUS )" >> "$CONF"
fi
for ck in $(printf '%s\n' "${!MIRRORPLUS[@]}" | sort); do
  line="MIRRORPLUS['$ck']=${MIRRORPLUS[$ck]}"
  if [[ -n "${ENABLED_REPOS[$ck]}" ]]; then
    # Repo is enabled: uncomment if commented, append if missing
    if grep -qF "#$line" "$CONF"; then
      sed -i "s|#${line}|${line}|" "$CONF"
    elif ! grep -qF "$line" "$CONF"; then
      echo "$line" >> "$CONF"
    fi
  else
    # Repo is not enabled: add commented out if not already present in any form
    if ! grep -qF "$line" "$CONF"; then
      echo "#$line" >> "$CONF"
    fi
  fi
done
sed -i 's|WGETOPTS="--timeout=20 --tries=2"|WGETOPTS="-q --timeout=20 --tries=2"|' "$CONF"
