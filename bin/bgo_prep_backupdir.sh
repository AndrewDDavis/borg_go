#!/usr/bin/env bash

# Make a list of installed software and packages, which can be used for later
# reinstallation in the case of disk failure.
#
# Part of the borg-go project, see: https://github.com/AndrewDDavis/borg_go

# Configure some common variables, shell options, and functions
set -eE

src_dir=$(python3 -c "import os; print(os.path.dirname(os.path.realpath('${BASH_SOURCE[0]}')))")
source "$src_dir/bgo_functions.sh"

# store these file and application lists in logged-in user's home
# - from bgo_functions: defines lognm, lognm_group, lognm_home
def_lognm

bakdir="$lognm_home/.local/backups"
[[ ! -d "$bakdir" ]] \
    && /bin/mkdir -p "$bakdir"


# Create a list of what's in /usr/local (nullglob is set)
echo $'/usr/local/\n'           >  "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/          >> "$bakdir"/usr-local-list.txt
echo $'\n\n/usr/local/*\n'      >> "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/*         >> "$bakdir"/usr-local-list.txt
/bin/ls -l /usr/local/share/man >> "$bakdir"/usr-local-list.txt

# - also show it in tree form
command tree -a /usr/local > "$bakdir"/usr-local-tree.txt


# The (p/m)locate db also contains paths for most files on the system
if [[ -n ${LOCATE_PATH:-} ]]
then
    dbfile=$LOCATE_PATH

elif [[ -r /var/lib/plocate/plocate.db ]]
then
    dbfile=/var/lib/plocate/plocate.db
fi

if [[ -r ${dbfile:-} ]]
then
    /bin/cp -p "$dbfile" "$bakdir"
fi


# List packages installed through npm, pip, pipx, and flatpak
# - you may need to pass PIPX_GLOBAL_HOME if set

if npm_pth=$( builtin type -P npm )
then
    "$npm_pth" --version > "${bakdir}/npm-list-g.txt"
    "$npm_pth" list -g --depth=0 >> "${bakdir}/npm-list-g.txt"
fi

if pip_pth=$( builtin type -P pip )
then
    "$pip_pth" --version > "${bakdir}/pip-list.txt"
    "$pip_pth" list >> "${bakdir}/pip-list.txt"
fi

if pipx_pth=$( builtin type -P pipx )
then
    if [[ ! -v PIPX_GLOBAL_HOME && -d /usr/local/opt/pipx ]]
    then
        export PIPX_GLOBAL_HOME=/usr/local/opt/pipx
    fi

    "$pipx_pth" --version > "${bakdir}/pipx-list-global.txt"
    "$pipx_pth" list --global >> "${bakdir}/pipx-list-global.txt"
fi

if fp_pth=$( builtin type -P flatpak )
then
    "$fp_pth" --version > "${bakdir}/flatpak-list-app.txt"
    "$fp_pth" list --app >> "${bakdir}/flatpak-list-app.txt"
fi

# Back up "Session Buddy" backup files of the Chrome state, if any
# - probably in ~/Downloads
command find "$lognm_home"/Downloads/ -maxdepth 2 \
    -name 'session_buddy_backup*.json' \
    -exec /bin/mv -f {} "$bakdir" \;


# Backup VS-Code user settings files
if [[ -r "$lognm_home"/.config/Code/User/settings.json ]]
then
    vsc_bakdir="$bakdir"/vscode-user_config
    /bin/mkdir -p "$vsc_bakdir"
    for fn in "$lognm_home"/.config/Code/User/{settings.json,keybindings.json,snippets}
    do
        [[ -r $fn ]] && /bin/cp -pLRf "$fn" "$vsc_bakdir"/
    done
    unset fn vsc_bakdir
fi


### OS dependent files

def_mach_id  # from bgo_functions: defines mach_name and mach_os

if [[ $mach_os == linux ]]
then
    # create a list of installed packages from dpkg
    # - Source for dpkg cmd:
    #   http://www.webupd8.org/2010/03/2-ways-of-reinstalling-all-of-your.html
    # - Note, /var/backups contains backups of the dpkg-status file, but that doesn't
    #   appear to indicate manual vs automatic installations.

    dpkg --get-selections > "$bakdir"/dpkg-installed-applications.txt

    # specifically note manually installed packages
    apt-mark showmanual > "$bakdir"/apt-manual-packages.txt

    # To restore the dpkg list, use:
    #  sudo dpkg --set-selections < dpkg-installed-applications.txt
    #  sudo apt-get -y update
    #  sudo apt-get dselect-upgrade

    if [[ -n $( command -v dconf ) ]]
    then
        # back up gsettings database if available
        dconf dump / > "$bakdir"/dconf-dump_backup.dump
    fi

elif [[ $mach_os == macos ]]
then
    # create a list of installed applications (nullglob is set)
    /bin/ls -l /Applications/ /Users/*/Applications/ > "$bakdir"/applications-list.txt
else
    raise 2 "Undefined mach_os: $mach_os"
fi

# chown these files to user
# - could also use ACLs with setfacl here, to preserve orig ownership
chown -R "$lognm":"$lognm_group" "$bakdir"
