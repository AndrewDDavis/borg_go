#!/usr/bin/env bash

# Make a list of installed software and packages, which can be used for later
# reinstallation in the case of disk failure.
#
# Part of the borg_go project, see: https://github.com/AndrewDDavis/borg_go

# Configure some common variables, shell options, and functions
BS0="${BASH_SOURCE[0]}"
exc_fn=$(basename -- "$BS0")
exc_dir=$(dirname -- "$BS0")

src_dir=$(python -c "import os; print(os.path.dirname(os.path.realpath('$BS0')))")
source "$src_dir/bgo_functions.sh"

# store these file and application lists in logged-in user's home
def_luser  # luser, luser_group, luser_home from bgo_functions

bakdir="$luser_home/.backup"
[[ -d "$bakdir" ]] || { echo "bakdir not found: $bakdir"; exit 2; }

# create a list of what's in /usr/local
echo $'/usr/local/\n'        > "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/      >> "$bakdir"/usr-local-list.txt
echo $'\n\n/usr/local/*\n'  >> "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/*     >> "$bakdir"/usr-local-list.txt

# back up "Session Buddy" backup files of the Chrome state, if found (nullglob is set)
# [[ -n $(compgen -G "$luser_home/Downloads/session_buddy_backup*.json") ]] \
#     && /bin/mv "$luser_home"/Downloads/session_buddy_backup*.json "$bakdir"
for fn in "$luser_home"/Downloads/session_buddy_backup*.json; do
  /bin/mv "$fn" "$bakdir"
done



def_mach_id  # mach_name and mach_os from bgo_functions

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

    # create a list of installed applications
    /bin/ls -l /Applications/ /Users/*/Applications/ > "$bakdir"/applications-list.txt
else
    raise 2 "Undefined mach_os: $mach_os"
fi

# chown these files to user
chown -R "$luser":"$luser_group" "$bakdir"
