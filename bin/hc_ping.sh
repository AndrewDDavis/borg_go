#!/usr/bin/env bash

# This script sends a signal to healthchecks.io to indicate the status of a
# BorgBackup job
#
# by Andrew Davis (addavis@gmail.com)
# v0.1 (Jun 2022)

function print_usage { cat << EOF

  hc_ping
  -------

  This script sends a signal to the relevant healthchecks.io URL to indicate
  progress or errors during a back-up with BorgBackup. It is normally called
  from borg_go.

  Usage: hc_ping <command> [optional messages]

  Commands:
    failure   -> signals that job has failed
    success   -> signals that job has completed successfully
    start     -> signals that job has started (provide command list with -m)
    exco <n>  -> signals exit code of job (0=success)

  Options:
    -m <ping_msg> -> message to include as data in the ping
    --cstats      -> include output of create --stats as data in the ping
    --pstats      -> include output of prune --stats as data in the ping

EOF
}

# Robust options
set -o nounset    # fail on unset variables
set -o errexit    # fail on non-zero return values
set -o errtrace   # make shell functions, subshells, etc obey ERR trap
set -o pipefail   # fail if any piped command fails
shopt -s extglob  # allow extended pattern matching

# print_msg function
# - prints log-style messages
# - usage: print_msg ERROR "the script had a problem"
script_bn=$(basename -- "$0")

function print_msg {
    local msg_type=INFO

    [[ $1 == @(DEBUG|INFO|WARNING|ERROR) ]] \
        && { msg_type=$1; shift; }

    printf "%s %s %s\n" "$(date)" "$script_bn [$msg_type]" "$*" >&2
}

# handle interrupt and exceptions
trap 'raise 2 "$script_bn was interrupted${FUNCNAME:+ (function $FUNCNAME)}"' INT TERM
trap 'raise $? "Exception in $0 at line $LINENO${FUNCNAME:+ (function $FUNCNAME)}"' ERR

# raise function
# - prints error message and exits with code
# - usage: raise 2 "valueError: foo should not be 0"
#          raise w "file missing, that's not great but OK"
function raise {
    local msg_type=ERROR
    local ec=${1:?"raise function requires exit code"}
    [[ $ec == w ]] && { msg_type=WARNING; ec=0; }

    print_msg "$msg_type" "${2:?"raise function requires message"}"
    exit $ec
}

# Parse and check arguments
[[ $# -eq 0 ]] && { print_usage; exit 0; }

while [ $# -gt 0 ]; do
    case $1 in
        start | success | failure | exco )
            hc_cmd=$1
            [[ $1 == exco ]] && { ec_val=$2; shift; } ;;
        -m )
            ping_msg=$2
            shift ;;
        --cstats )
            stats=cstats ;;
        --pstats )
            stats=pstats ;;
        -h | --help )
            print_usage
            exit 0 ;;
        * )
            raise 2 "Unrecognized option: '$1'" ;;
    esac
    shift
done

[[ -n ${hc_cmd:-} ]] \
    || raise w "No actions to perform, stay frosty"

[[ -n $(command -v curl) ]] \
    || raise 2 "curl not found"

# Import UUID
# - exit gracefully if UUID file doesn't exist
uuid_file="${BORG_CONFIG_DIR}/healthchecks_UUID.txt"
[[ -e $uuid_file ]] \
    || raise w "skipping ping, uuid_file not found: '$uuid_file'"

hc_uuid=$(< "$uuid_file") \
    || raise 2 "unable to read uuid_file: '$uuid_file'"

# should be 36 chars
[[ ${#hc_uuid} -eq 36 ]] \
    || raise 2 "hc_uuid not as expected: '$hc_uuid'"


# base of healthchecks URL to ping
hc_url='https://hc-ping.com'


function send_ping {
    # ping healthchecks.io with the relevant info
    # - see the healthchecks pinging API docs: https://healthchecks.io/docs/http_api/
    # - and the bash docs: https://healthchecks.io/docs/bash/
    # - view recent pings at: https://healthchecks.io/checks/UUID/details/
    # - NB1: with no trailing status, the signal is success
    # - NB2: when sending exit-status, 0=success, all other failure

    # usage: send_ping

    # set full URL for healthchecks
    # - trailing part can be either empty (for success), or start, fail, or
    #   integer representing an exit code
    local full_url="${hc_url}/${hc_uuid}"

    [[ -n ${1:-} ]] && full_url+="/$1"

    # check for `borg create/prune --stats` output if requested
    if [[ ${stats:-} == cstats && -r "${BORG_CONFIG_DIR}/borg_log_create-stats.txt" ]]; then
        local stats_fn="${BORG_CONFIG_DIR}/borg_log_create-stats.txt"

    elif [[ ${stats:-} == pstats && -r "${BORG_CONFIG_DIR}/borg_log_prune-stats.txt" ]]; then
        local stats_fn="${BORG_CONFIG_DIR}/borg_log_prune-stats.txt"
    fi

    # curl command
    # - sends GET request unless --data is used, then POST
    # - use --output /dev/null to get rid of output
    # - if ping_msg exists, add it as data
    hc_reponse=$(curl --max-time 10 --retry 10                         \
                      --fail --silent --show-error                     \
                      ${ping_msg:+--data-raw "$ping_msg"} \
                      ${stats_fn:+--data-raw "$(< "$stats_fn")"}       \
                      "$full_url")

    echo "$hc_reponse"
}


# process command
case $hc_cmd in
    start )   hc_reponse=$(send_ping start) ;;
    failure ) hc_reponse=$(send_ping fail) ;;
    success ) hc_reponse=$(send_ping) ;;
    exco )    hc_reponse=$(send_ping $ec_val) ;;
esac


# exit, byebye
if [[ $hc_reponse == OK ]]; then

    print_msg "- $hc_cmd signal sent to Healthchecks"
    exit 0
else
    raise 1 "Healthchecks response: '$hc_reponse'"
fi
