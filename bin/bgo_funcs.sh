# shellcheck shell=bash

_bg_args() {

    # Parse arguments
    [[ $# -eq 0  || $1 == @(-h|--help|help) ]] \
        && { docsh -TDf borg-go; exit 0; }

    trap 'return' ERR
    trap 'trap - return err' RETURN

    while (( $# > 0 ))
    do
        case $1 in
            ( create | prune | check | compact )
                cmd_array+=( "$1" )
            ;;
            ( list | log )
                cmd_array+=( "$1" )
                bgl_args=( "${@:2}" )
                shift $#
                break
            ;;
            ( --local )
                _local=1
            ;;
            ( --all )
                _chk_all=1
            ;;
            ( -n | --dry-run )
                _dryrun='--dry-run'
            ;;
            ( -v | --verbose )
                (( ++_verb ))
            ;;
            ( * )
                # option(s) and args for a command
                (( ${#cmd_array[*]} == 0 )) \
                    && err_msg -d 3 "No command, but received argument '$1'"

                case ${cmd_array[-1]} in
                    (create)
                        if [[ $1 == -* ]]
                        then
                            cre_args+=( "$1" )
                        else
                            # rec_root paths
                            rr_paths+=( "$1" )
                        fi
                        ;;
                    (prune)   pru_args+=( "$1" ) ;;
                    (check)   chk_args+=( "$1" ) ;;
                    (compact) com_args+=( "$1" ) ;;
                esac
            ;;
        esac
        shift
    done

    # Check for valid command(s)
    (( ${#cmd_array[*]} > 0 )) \
        || err_msg -d 2 "No valid commands received, stay frosty."
}

_bg_pre-run() {

    trap 'return' ERR
    trap 'trap - return err' RETURN

    # Borg environment variables
    # - Some variables are set in ~/.bashrc or launchd plist, and retained by sudo,
    #   per my sudoers policy: BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF, and
    #   BORG_EXIT_CODES.
    # - When running unencrypted locally or over a LAN, BORG_PASSPHRASE is unset.
    # - Cache and security dirs should go in root's home when running under sudo.
    #   This is to prevent permissions problems when later running e.g. `borg info`
    #   as regular user.
    [[ -n ${BORG_CONFIG_DIR-} ]] \
        || export BORG_CONFIG_DIR=${lognm_home}/.config/borg

    export BORG_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/borg
    export BORG_SECURITY_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/borg/security

    if (( running_user != 0 )) \
        && array_match cmd_array create \
        && [[ ! -v _local ]]
    then
        # running as root enforced
        # - See the ReadMe for discussion on the running user for borg
        err_msg -d 3 "root or sudo required for remote repo commands beyond list"
    fi

    # Lock file
    if [[ -e ${BORG_CONFIG_DIR}/borg-go.lock ]]
    then
        err_msg -d 2 "lock file found: '${BORG_CONFIG_DIR}/borg-go.lock'"
    else
        printf '%s\n' "$$" > "${BORG_CONFIG_DIR}/borg-go.lock"
    fi

    # repo and archive defn
    if [[ -v _local ]]
    then
        unset BORG_REPO
        [[ -n ${BORG_LOCAL_REPO-} ]] \
            || err_msg -d 6 "local repo required; set BORG_LOCAL_REPO"

        repo_uri=$( physpath "$BORG_LOCAL_REPO" )

        # confirm repo is initialized
        local repo_chk
        repo_chk=$( < "$repo_uri/README" ) \
            && [[ $repo_chk == *borg* ]] \
            || err_msg -d 7 "local repo check failed; is '$repo_uri' initialized?"

        vrb_msg 2 "using local repo: '${repo_uri}'"

    else
        # use BORG_REPO
        [[ -n ${BORG_REPO-} ]] || ( exit 4 )
        repo_uri=::
    fi


    # ensure logging is set up
    [[ -n ${BORG_LOGGING_CONF-} ]] || ( exit 5 )

    logging_dir=$BORG_CONFIG_DIR/log
    [[ -d $logging_dir ]] \
        || /bin/mkdir -p "$logging_dir"

    if [[ -v _dryrun ]]
    then
        # - use a separate log file on dry-runs, and overwrite every time
        # - e.g. logging.conf becomes logging-dryrun.conf
        BORG_LOGGING_CONF=${BORG_LOGGING_CONF/%.conf/-dryrun.conf}
        log_fn=$logging_dir/borg_dryrun_log
        vrb_msg 2 "using dry-run log: '${log_fn}'"

    elif [[ -v _local ]]
    then
        # - similarly for --local runs
        BORG_LOGGING_CONF=${BORG_LOGGING_CONF/%.conf/-local.conf}
        log_fn=$logging_dir/borg_local_log
        vrb_msg 2 "using local log: '${log_fn}'"

    else
        # - borg should append for this session, per logging.conf, but bg_create
        #   does rotate the log files
        log_fn=$logging_dir/borg_log
    fi

    [[ -e $BORG_LOGGING_CONF ]] ||
        err_msg -d 5 "BORG_LOGGING_CONF file not found: '$BORG_LOGGING_CONF'"


    # mount repo if needed (erikson, mendeleev)
    if [[ -v BORG_MNT_REQD ]] && (( BORG_MNT_REQD ))
    then
        err_msg -d i "Mounting backup repo"
        bgo_scr_run bgo_check_mount
    fi

    # otherwise, check that ssh connection is possible
    if [[ -v BORG_REPO && ${BORG_REPO:0:6} == "ssh://" ]]
    then
        _rem=${BORG_REPO:6}
        _rem=${_rem%%/*}        # e.g. user@host
        command ssh "$_rem" true
    fi
}

_bg_post-run() {

    if [[ -v BORG_MNT_REQD ]] && (( BORG_MNT_REQD ))
    then
        # unmount
        err_msg -d i "Unmounting backup repo"
        bgo_scr_run bgo_check_mount -u
    fi

    if (( running_user == 0 ))
    then
        # chown log files owned by root to user login name
        # - e.g. borg_log, borg_log.0, borg_local_log, borg_log_chfile_sizes
        # - should only be necessary for newly created files
        # - lognm, lognm_group, etc. are set in bgo_env_setup
        "$find_cmd" "$logging_dir" \
            \( \
                -name 'borg_*log*' \
                -o -name 'borg-go_*_out' \
            \) \
            -user "$( command id -un 0 )" \
            -exec "$chown_cmd" "$lognm":"$lognm_group" '{}' \;
    fi

    err_msg -d i "borg-go done"

    if [[ -v cre_rc ]] && (( cre_rc == 0 ))
    then
        err_msg -d i " (create status: success)"
    elif [[ -v cre_rc ]]
    then
        err_msg -d i " (create status: $cre_rc)"
    fi

    if [[ -v chk_rc ]] && (( chk_rc == 0 ))
    then
        err_msg -d i " (check status: success)"
    elif [[ -v chk_rc ]]
    then
        err_msg -d i " (check status: $chk_rc)"
    fi
}

bgo_scr_run() {

    # usage:
    #   bgo_scr_run bgo_ping_hc success ...
    #   bgo_scr_run --check bgo_prep_backupdir

    # NB, for a function, just use:
    # import_func -l funcname

    local _chk
    [[ $1 == --check ]] \
        && { _chk=1; shift; }

    local scr_name=${src_dir}/${1}.sh
    shift

    [[ -x $scr_name ]] \
        || { err_msg -d 9 "no executable found at ${scr_name}"; return; }

    if [[ -v _chk ]]
    then
        return 0
    else
        "$scr_name" "$@" \
            || return
    fi
}

handle_borg_ec() {

    # Handle non-zero exit codes from borg
    # - borg exits with ec=1 or 100-127 for warnings, which shouldn't
    #   bring down the whole script, but should be reported
    local -i ec=$1
    shift

    case ${FUNCNAME[1]} in
        ( bg_create ) cre_rc=$ec ;;
        ( bg_check ) chk_rc=$ec ;;
    esac

    if (( ec == 1 || ( ec > 99 && ec < 128 ) ))
    then
        # relay borg warning
        hc_msg="${FUNCNAME[1]}(): borg exited with code $ec; WARNINGs from ${log_fn}:"$'\n'
        hc_msg+=$( "$grep_cmd" WARNING "$log_fn" )$'\n'
        err_msg -d w "$hc_msg"
        return 0

    else
        # trigger the ERR trap
        return $ec
    fi
}
