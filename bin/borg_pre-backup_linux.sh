#!/bin/bash

# Make a list of installed software and packages for later reinstallation
# Must be run as root for dpkg; use `sudo -E` to ensure correct $HOME
#
# Source for dpkg cmd: http://www.webupd8.org/2010/03/2-ways-of-reinstalling-all-of-your.html
#
# To restore the list, use:
#  sudo dpkg --set-selections < installed-applications.txt
#  sudo apt-get -y update
#  sudo apt-get dselect-upgrade

# location to store these file and application lists
bakdir="/home/andrew/.backup"
[[ -d "$bakdir" ]] || { echo "bakdir not found: $bakdir"; exit 2; }

# create a list of what's in /usr/local
echo -e "/usr/local/\n"       > "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/       >> "$bakdir"/usr-local-list.txt
echo -e "\n\n/usr/local/*\n" >> "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/*      >> "$bakdir"/usr-local-list.txt

# create a list of installed packages from dpkg
dpkg --get-selections > "$bakdir"/dpkg-installed-applications.txt

# specifically note manually installed packages
apt-mark showmanual > "$bakdir"/apt-manual-packages.txt

# chown these files to user
chown -R andrew:andrew "$bakdir"
