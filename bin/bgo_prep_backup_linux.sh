#!/bin/bash

# Make a list of installed software and packages for later reinstallation
#
# Source for dpkg cmd: http://www.webupd8.org/2010/03/2-ways-of-reinstalling-all-of-your.html
#
# To restore the list, use:
#  sudo dpkg --set-selections < installed-applications.txt
#  sudo apt-get -y update
#  sudo apt-get dselect-upgrade

# This script must be run as root for dpkg, and is likely run using `sudo -EH` during a
# borg backup, meaning HOME will be root's home. Get the logged-in user's home instead:
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

# create a list of installed packages from dpkg
dpkg --get-selections > "$bakdir"/dpkg-installed-applications.txt

# specifically note manually installed packages
apt-mark showmanual > "$bakdir"/apt-manual-packages.txt

# chown these files to user
chown -R "$luser:$luser_group" "$bakdir"
