#!/bin/bash

# Make a list of installed software and packages for later reinstallation

# This file is likely run using `sudo -EH` during a borg backup, meaning HOME
# will be root's home. Get the logged-in user's home instead:
luser=$(logname 2>/dev/null) \
    || luser=$(echo "${BORG_CONFIG_DIR}" | sed -E 's|/[^/]*/([^/]*)/.*|\1|')  # no logname when run with systemd $(id -un)

luser_group=$(id -gn "$luser")
luser_home=$(eval echo ~"$luser")  # works as variable replacement done before running

# location to store these file and application lists
bakdir="$luser_home/.backup"
[[ -d "$bakdir" ]] || { echo "bakdir not found: $bakdir"; exit 2; }

# create a list of what's in /usr/local
echo "/usr/local/"$'\n'          > "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/          >> "$bakdir"/usr-local-list.txt
echo $'\n\n'"/usr/local/*"$'\n' >> "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/*         >> "$bakdir"/usr-local-list.txt

# create a list of installed applications
/bin/ls -l /Applications/ /Users/*/Applications/ > "$bakdir"/applications-list.txt

# back up "Session Buddy" backup files of the Chrome state, if found
[[ -n $(compgen -G "$luser_home"/Downloads/session_buddy_backup*.json) ]] \
    && /bin/mv "$luser_home"/Downloads/session_buddy_backup*.json "$bakdir"

# chown these files to user
chown -R "$luser:$luser_group" "$bakdir"
