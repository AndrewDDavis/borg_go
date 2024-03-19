# Library of functions to support the borg-go project
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
# src_dir=$(python3 -c "import os; print(os.path.dirname(os.path.realpath('$BS0')))")
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
[[ $0 == borg-go?(.sh) ]] && bgo_ping_hc failure -m "$ping_msg"
raise $ec "$ping_msg"' ERR

handle_pipefails() {
    # Ignore exit code 141 (pipefail, or sigpipe received) from simple command pipes.
    # - This occurs when a program (e.g. `head -1`) stops reading from a pipe.
    # - See [my answer][1] for details.
    #   [1]: https://unix.stackexchange.com/a/709880/85414
    # Usage:
    #   cmd1 | cmd2 || handle_pipefails $?
    # E.g. to test:
    #   yes | head -n 1 || handle_pipefails $?
    # Returns 0 for $1=141, or returns the value of $1 otherwise.
    (( $1 == 141 )) || return $1
}

def_mach_id() {
    # Set variables for machine name and OS

    mach_name=$(hostname -s)
    mach_name=${mach_name,,}    # lowercase

    mach_os=$(uname -s)
    mach_os=${mach_os,,}
    [[ $mach_os == "darwin" ]] && mach_os=macos

    return 0
}

def_lognm() {
    # These scripts are likely run using `sudo` during a borg backup, meaning HOME
    # will be root's home. We can define the login name of user running sudo using
    # logname (checks owner of the tty)
    lognm=$(logname 2>/dev/null) || true

    # Handle case of running without sudo: when running with Systemd, Linux produces an
    # error code and an empty string; when running with Launchd, macOS produces
    # /var/empty for the home dir. In those cases, try to parse BORG_CONFIG_DIR for a
    # username:
    [[ -z $lognm || ~$lognm == /var/empty ]] \
        && lognm=$(sed -E 's|/[^/]+/([^/]+)/.*|\1|' <<<"$BORG_CONFIG_DIR")

    lognm_group=$(id -gn "$lognm")
    lognm_home=$(eval echo ~"$lognm")  # NB variable replacement done _before_ execution

    [[ $lognm_home != "~$lognm" ]] || raise 2 "failed to get lognm: '$lognm'"
}
