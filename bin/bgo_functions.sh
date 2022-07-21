# Library of functions to support the borg_go project
# See: https://github.com/AndrewDDavis/borg_go
#
# v0.1 (Jul 2022) by Andrew Davis (addavis@gmail.com)
#
# This file is meant to be sourced, not run. Typical syntax:
#
# # Configure some common variables, shell options, and functions
# # - BASH_SOURCE (and 0) likely refer to symlink
# # - exc_fn and exc_dir refer to the executable path as called, while
# #   src_dir refers to the resolved absolute canonical path to the script dir
# BS0="${BASH_SOURCE[0]}"
# exc_fn=$(basename -- "$BS0")
# exc_dir=$(dirname -- "$BS0")
#
# src_dir=$(python -c "import os; print(os.path.dirname(os.path.realpath('$BS0')))")
# source "$src_dir/bgo_functions.sh"


# Set preferred shell options for more robust scripts
set -o nounset     # fail on unset variables
set -o errexit     # fail on non-zero return values
set -o errtrace    # make shell functions, subshells, etc obey ERR trap
set -o pipefail    # fail if any piped command fails
shopt -s extglob   # allow extended pattern matching
shopt -s nullglob  # non-matching glob patterns return null string

# UMask -- no write for group, nothing for other
umask 027

print_msg() {
    # Print log-style messages to stderr
    # - usage: print_msg ERROR "the script had a problem"
    local msg_type=INFO

    [[ $1 == @(DEBUG|INFO|WARNING|ERROR) ]] \
        && { msg_type=$1; shift; }

    printf >&2 "%s %s %s\n" "$(date)" "${exc_fn--} [$msg_type]" "$*"
}

raise() {
    # Print error message and exit with code
    # - usage: raise 2 "valueError: foo should not be 0"
    #          raise w "file missing, that's not great but OK"
    local ec=${1:?"raise function requires exit code"}
    local msg_body=${2:?"raise function requires message"}
    local msg_type=ERROR
    [[ $ec == w ]] && { msg_type=WARNING; ec=0; }

    print_msg "$msg_type" "$msg_body"
    exit $ec
}

# Handle interrupt and exceptions, giving useful debugging output
trap -- 'raise 2 "${exc_fn--} was interrupted${FUNCNAME:+ (function $FUNCNAME)}"' INT TERM
trap -- 'ec=$?
ping_msg="Exception $ec in $0 at line $LINENO${FUNCNAME:+ (function stack: ${FUNCNAME[@]})}"
[[ $0 == borg_go?(.sh) ]] && bgo_ping_hc failure -m "$ping_msg"
raise $ec "$ping_msg"' ERR


def_mach_id() {
    # Set variables for machine name and OS

    mach_name=$(hostname -s)
    mach_name=${mach_name,,}    # lowercase

    mach_os=$(uname -s)
    mach_os=${mach_os,,}
    [[ $mach_os == "darwin" ]] && mach_os=macos
}


def_luser() {
    # These scripts are likely run using `sudo -EH` during a borg backup, meaning HOME
    # will be root's home. We can define the login name of user running sudo using
    # logname (checks owner of the tty)
    luser=$(logname 2>/dev/null) || true

    # When running with systemd or launchd, Linux produces an error code, and macOS
    # produces /var/empty for the home dir. In those cases, grab the username from
    # BORG_CONFIG_DIR:
    [[ -z $luser || ~$luser == /var/empty ]] \
        && luser=$(sed -E 's|/[^/]*/([^/]*)/.*|\1|' <<<"$BORG_CONFIG_DIR")

    luser_group=$(id -gn $luser)
    luser_home=$(eval echo ~$luser)  # NB variable replacement done _before_ execution
}
