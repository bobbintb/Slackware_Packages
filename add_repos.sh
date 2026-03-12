#!/bin/bash

REPOPLUS="slackpkgplus"
REPOS="$@"

        declare -A REPO_IDS
        while IFS=$'\t' read -r repo_entry_id repo_entry_brief repo_entry_version; do
          [ -z "$repo_entry_brief" ] && continue
          REPO_IDS["$repo_entry_brief $repo_entry_version"]="$repo_entry_id"
        done < <(
          curl -s "https://slackware.nl/slakfinder/showrepo.php" \
            | grep '<tr ><td' \
            | sed 's|.*<td >\([^<]*\)</td><td ><[^>]*>\([^<]*\)</a></td><td >\([^<]*\)</td><td >\([^<]*\)</td><td >\([^<]*\)<br>.*|\1\t\2\t\3\t\4\t\5|' \
            | awk -F'\t' '$3 == "x86_64" && ($4 == "current" || $4 == "15.0") {print $1 "\t" $2 "\t" $4}'
        )

        # Parse REPOS input into an array
        # Each entry is in the form brief-version (e.g. AlienBOB-15.0 or alien_bob-current)
        # - separates brief from version, _ replaces spaces in brief, matching is case-insensitive
        read -ra REPOS_ARRAY <<< $REPOS
        for name in "${REPOS_ARRAY[@]}"; do
          version="${name##*-}"
          brief_raw="${name%-*}"
          brief_lookup=$(echo "$brief_raw" | tr '_' ' ' | tr '[:upper:]' '[:lower:]')

          repo_id=""
          matched_key=""
          for key in "${!REPO_IDS[@]}"; do
            key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')
            key_version="${key_lower##* }"
            key_brief="${key_lower% *}"
            if [ "$key_brief" = "$brief_lookup" ] && [ "$key_version" = "$version" ]; then
              repo_id="${REPO_IDS[$key]}"
              matched_key="$key"
              break
            fi
          done

          if [ "$brief_lookup" = "bobbintb" ]; then
            REPOPLUS+=" bobbintb"
            echo "Enabled: bobbintb"
          elif [ -n "$repo_id" ]; then
            config_key=$(echo "$matched_key" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
            REPOPLUS+=" $config_key"
            echo "Enabled: $config_key"
          else
            echo "Warning: repo '$name' not found in slakfinder, skipping"
          fi
        done

        # Update REPOPLUS first: uncomment if commented out, replace if exists, create if missing
        if grep -q "^#.*REPOPLUS=" /etc/slackpkg/slackpkgplus.conf; then
          sed -i "s|^#.*REPOPLUS=.*|REPOPLUS=( $REPOPLUS )|" /etc/slackpkg/slackpkgplus.conf
        elif grep -q "^REPOPLUS=" /etc/slackpkg/slackpkgplus.conf; then
          sed -i "s|^REPOPLUS=.*|REPOPLUS=( $REPOPLUS )|" /etc/slackpkg/slackpkgplus.conf
        else
          echo "REPOPLUS=( $REPOPLUS )" >> /etc/slackpkg/slackpkgplus.conf
        fi

        # Fetch URLs for all known x86_64 repos, sort alphabetically, then write MIRRORPLUS lines
        declare -A MIRRORPLUS_LINES
        MIRRORPLUS_LINES["bobbintb"]="https://bobbintb.github.io/Slackware_Packages/builds/"
        for key in "${!REPO_IDS[@]}"; do
          repo_id="${REPO_IDS[$key]}"
          url=$(curl -s "https://slackware.nl/slakfinder/showrepo.php?repo=$repo_id" \
            | grep -A1 "<td >URL</td>" \
            | sed -n "s|.*href='\([^']*\)'.*|\1|p")
          config_key=$(echo "$key" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
          MIRRORPLUS_LINES["$config_key"]="$url"
        done
        for config_key in $(echo "${!MIRRORPLUS_LINES[@]}" | tr ' ' '\n' | sort); do
          mirrorplus_line="MIRRORPLUS['$config_key']=${MIRRORPLUS_LINES[$config_key]}"
          if ! grep -qF "$mirrorplus_line" /etc/slackpkg/slackpkgplus.conf; then
            echo "$mirrorplus_line" >> /etc/slackpkg/slackpkgplus.conf
          fi
        done
        sed -i 's|WGETOPTS="--timeout=20 --tries=2"|WGETOPTS="-q --timeout=20 --tries=2"|' /etc/slackpkg/slackpkgplus.conf
