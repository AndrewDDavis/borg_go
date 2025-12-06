# Functions and config to support the borg-go project
# See: https://github.com/AndrewDDavis/borg_go
#
# v0.1 (Jul 2022) by Andrew Davis (addavis@gmail.com)
#
# This file is meant to be sourced, not run. It should not be executable.

# shellcheck shell=bash

# Set preferred shell options
set -o nounset     # fail on unset variables (set -u)
# set -o errexit     # fail on non-zero return values
# set -o errtrace    # make shell functions, subshells, etc obey ERR trap
set -o pipefail    # fail if any piped command fails
shopt -s extglob   # allow extended pattern matching
shopt -s nullglob  # non-matching glob patterns return null string

running_user=$( command id -u )

# UMask -- no write for group, nothing for other
umask 027

# Handle interrupt and exceptions, giving useful debugging output
trap -- '
    err_msg -d 2 "${exc_fn--} was interrupted${FUNCNAME[0]:+ (function ${FUNCNAME[0]})}"
    exit
' INT TERM

trap -- '
    ec=$?
    ping_msg="$( date +"%F %T %Z" ) Exception code $ec in $( basename -- ${BASH_SOURCE[0]} ) script at line $((LINENO-2))${FUNCNAME[0]:+ (function stack: ${FUNCNAME[@]})}"

    [[ $0 == borg-go?(.sh) ]] \
        && bgo_ping_hc failure -m "$ping_msg"

    printf "%s\n" "${ping_msg}; exiting..."
    exit $ec
' ERR

# remove lock file
trap -- '
    /bin/rm -f "${BORG_CONFIG_DIR}/borg-go.lock"
' EXIT

# Verbosity
_verb=1

def_cmds() {

    # define command paths
    borg_cmd=$( builtin type -P borg )
    chown_cmd=$( builtin type -P chown )
    find_cmd=$( builtin type -P find )
    grep_cmd=$( builtin type -P grep )
    sed_cmd=$( builtin type -P sed )
    tail_cmd=$( builtin type -P tail )
}

def_mach_id() {

    # Set variables for machine name and OS

    mach_name=$( hostname -s )
    mach_name=${mach_name,,}    # lowercase

    mach_os=$( uname -s )
    mach_os=${mach_os,,}
    [[ $mach_os != "darwin" ]] \
        || mach_os=macos
}

def_lognm() {

    # These scripts are likely run using `sudo` during a borg backup, meaning HOME
    # will be root's home. We can define the login name of user running sudo using
    # logname (checks owner of the tty)
    lognm=$( logname 2>/dev/null ) || true

    # Handle case of running without sudo: when running with Systemd, Linux produces an
    # error code and an empty string; when running with Launchd, macOS produces
    # /var/empty for the home dir. In those cases, try to parse BORG_CONFIG_DIR for a
    # username:
    [[ -z $lognm  || ~$lognm == /var/empty ]] \
        && lognm=$( "$sed_cmd" -E 's|/[^/]+/([^/]+)/.*|\1|' <<< "$BORG_CONFIG_DIR" )

    lognm_group=$( id -gn "$lognm" )
    eval lognm_home=~"$lognm"           # variable replacement, then eval tilde expansion

    [[ $lognm_home != "~$lognm" ]] \
        || { err_msg -d 2 "failed to get lognm: '$lognm'"; exit; }
}

[[ -v borg_cmd ]] \
    || def_cmds

[[ -v mach_name ]] \
    || def_mach_id

[[ -v lognm ]] \
    || def_lognm
