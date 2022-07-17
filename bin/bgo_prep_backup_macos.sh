#!/bin/bash

# Make a list of installed software and packages, which can be used for later
# reinstallation in the case of disk failure.
#
# Part of the borg_go project, see: https://github.com/AndrewDDavis/borg_go

# Configure some common variables, shell options, and functions
src_bn=$(basename -- "${BASH_SOURCE[0]}")
src_dir=$(dirname -- "${BASH_SOURCE[0]}")

source "${src_dir}"/bgo_functions.sh

# store these file and application lists in logged-in user's home
def_luser  # luser, luser_group, luser_home from bgo_functions

bakdir="$luser_home/.backup"
[[ -d "$bakdir" ]] || { echo "bakdir not found: $bakdir"; exit 2; }

# create a list of what's in /usr/local
echo $'/usr/local/\n'        > "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/      >> "$bakdir"/usr-local-list.txt
echo $'\n\n/usr/local/*\n'  >> "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/*     >> "$bakdir"/usr-local-list.txt

# create a list of installed applications
/bin/ls -l /Applications/ /Users/*/Applications/ > "$bakdir"/applications-list.txt

# back up "Session Buddy" backup files of the Chrome state, if found
[[ -n $(compgen -G "$luser_home"/Downloads/session_buddy_backup*.json) ]] \
    && /bin/mv "$luser_home"/Downloads/session_buddy_backup*.json "$bakdir"

# chown these files to user
chown -R "$luser":"$luser_group" "$bakdir"
