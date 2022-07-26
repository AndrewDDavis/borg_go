#!/usr/bin/env bash

# Make a list of installed software and packages, which can be used for later
# reinstallation in the case of disk failure.
#
# Part of the borg_go project, see: https://github.com/AndrewDDavis/borg_go

# Configure some common variables, shell options, and functions
set -eE
BS0="${BASH_SOURCE[0]}"
exc_fn=$(basename -- "$BS0")
exc_dir=$(dirname -- "$BS0")

src_dir=$(python3 -c "import os; print(os.path.dirname(os.path.realpath('$BS0')))")
source "$src_dir/bgo_functions.sh"

# store these file and application lists in logged-in user's home
def_lognm  # from bgo_functions: defines lognm, lognm_group, lognm_home

bakdir="$lognm_home/.backup"
[[ -d "$bakdir" ]] || { echo "bakdir not found: $bakdir"; exit 2; }

# create a list of what's in /usr/local (nullglob is set)
echo $'/usr/local/\n'        > "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/      >> "$bakdir"/usr-local-list.txt
echo $'\n\n/usr/local/*\n'  >> "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/*     >> "$bakdir"/usr-local-list.txt

# back up "Session Buddy" backup files of the Chrome state, if any
find "$lognm_home"/Downloads -name 'session_buddy_backup*.json' -exec  \
    /bin/mv -f {} "$bakdir" \;


def_mach_id  # from bgo_functions: defines mach_name and mach_os

if [[ $mach_os == linux ]]; then

    # create a list of installed packages from dpkg
    # - Source for dpkg cmd:
    #   http://www.webupd8.org/2010/03/2-ways-of-reinstalling-all-of-your.html
    dpkg --get-selections > "$bakdir"/dpkg-installed-applications.txt

    # specifically note manually installed packages
    apt-mark showmanual > "$bakdir"/apt-manual-packages.txt

    # To restore the dpkg list, use:
    #  sudo dpkg --set-selections < installed-applications.txt
    #  sudo apt-get -y update
    #  sudo apt-get dselect-upgrade

elif [[ $mach_os == macos ]]; then

    # create a list of installed applications (nullglob is set)
    /bin/ls -l /Applications/ /Users/*/Applications/ > "$bakdir"/applications-list.txt
else
    raise 2 "Undefined mach_os: $mach_os"
fi

# chown these files to user
chown -R "$lognm":"$lognm_group" "$bakdir"
