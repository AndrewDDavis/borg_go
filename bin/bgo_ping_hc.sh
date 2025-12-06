#!/usr/bin/env bash

# by Andrew Davis (addavis@gmail.com)
# v0.2 (Aug 2025)

: """Send signal to healthchecks.io

  This function sends a signal to the relevant healthchecks.io URL to indicate
  progress or errors during a backup job with BorgBackup. It is normally called
  from borg-go.

  Usage: bgo_ping_hc <command> [optional messages]

  Commands

    failure   -> signals that job has failed
    success   -> signals that job has completed successfully
    start     -> signals that job has started (provide command list with -m)
    exco <n>  -> signals exit code of job (0=success)

  Options

    -m <ping_msg> -> message to include as data in the ping
    --cstats      -> include output of create --stats as data in the ping
    --pstats      -> include output of prune --stats as data in the ping
"""

bgo_ping_hc() {

    trap 'return' ERR
    trap 'trap - err return' RETURN

    # Parse and check arguments
    [[ $# -eq 0 || $1 == @(-h|--help) ]] \
        && { docsh -TD; return; }

    # don't ping with --local
    [[ -v _local ]] \
        && return 0

    while (( $# > 0 ))
    do
        case $1 in
            ( start | success | failure )
                hc_cmd=$1
            ;;
            ( exco )
                hc_cmd=$1
                ec_val=$2
                shift
            ;;
            ( -m )
                ping_msg=$2
                shift
            ;;
            ( --cstats )
                stats=cstats
            ;;
            ( --pstats )
                stats=pstats
            ;;
            ( * )
                err_msg -d 2 "Unrecognized option: '$1'"
            ;;
        esac
        shift
    done

    [[ -n ${hc_cmd:-} ]] \
        || err_msg -d w "No actions to perform, stay frosty"

    curl_cmd=$( builtin type -P curl ) \
        || err_msg -d 2 "curl not found"

    # Import UUID
    # - exit gracefully if UUID file doesn't exist
    uuid_file="${BORG_CONFIG_DIR}/healthchecks_UUID"
    [[ -e $uuid_file ]] \
        || { err_msg -d w "skipping ping, uuid_file not found: '$uuid_file'"; return; }

    hc_uuid=$( < "$uuid_file" ) \
        || err_msg -d 2 "unable to read uuid_file: '$uuid_file'"

    # should be 36 chars
    (( ${#hc_uuid} == 36 )) \
        || err_msg -d 2 "hc_uuid not as expected: '$hc_uuid'"

    # base of healthchecks URL to ping
    hc_url='https://hc-ping.com'

    # process command
    case $hc_cmd in
        ( start )
            hc_reponse=$( send_ping start )
        ;;
        ( failure )
            hc_reponse=$( send_ping fail )
        ;;
        ( success )
            hc_reponse=$( send_ping )
        ;;
        ( exco )
            hc_reponse=$( send_ping "$ec_val" )
        ;;
    esac

    # finish up
    if [[ $hc_reponse == OK ]]
    then
        err_msg -d i "$hc_cmd signal sent to Healthchecks"
    else
        err_msg -d 9 "Healthchecks response: '$hc_reponse'"
    fi
}

send_ping() {

    # ping healthchecks.io with the relevant info
    # - see the healthchecks pinging API docs: https://healthchecks.io/docs/http_api/
    # - and the bash docs: https://healthchecks.io/docs/bash/
    # - view recent pings at: https://healthchecks.io/checks/UUID/details/
    # - NB1: with no trailing status, the signal is success
    # - NB2: when sending exit-status, 0=success, all other failure

    # usage: send_ping <trailing_part>

    # set full URL for healthchecks
    # - trailing part can be either empty (for success), or start, fail, or
    #   integer representing an exit code
    local full_url="${hc_url}/${hc_uuid}"

    [[ -n ${1:-} ]] && full_url+="/$1"

    # check for `borg create/prune --stats` output if requested
    local stats_fn
    if [[ ${stats:-} == cstats && -r ${log_fn}_create-stats ]]
    then
        stats_fn=${log_fn}_create-stats

    elif [[ ${stats:-} == pstats && -r ${log_fn}_prune-stats ]]
    then
        stats_fn=${log_fn}_prune-stats
    fi

    # call curl
    # - sends GET request unless --data is used, then POST
    # - use --output /dev/null to get rid of output
    # - if ping_msg exists, add it as data
    hc_reponse=$( \
        "$curl_cmd" --max-time 10 --retry 10 \
            --fail --silent --show-error \
            ${ping_msg:+--data-raw "$ping_msg"} \
            ${stats_fn:+--data-raw "$(< "$stats_fn")"} \
            "$full_url"
    )

    printf '%s\n' "$hc_reponse"
}
