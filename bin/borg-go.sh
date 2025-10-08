#!/usr/bin/env bash

# This is borg-go, the main script to call borg using typical settings for this
# system.
#
# Inspired by the script in the official docs:
#   https://borgbackup.readthedocs.io/en/stable/quickstart.html#automating-backups
#
# by Andrew Davis (addavis@gmail.com)
# v0.3 (Aug 2025)

: """Run Borg-Backup with the typical config to create, prune, and check backups

    Usage

        borg-go [options] <command1 command2 ...>
        borg-go [options] command [command-arguments ...]

    Commands

      create
      : Create a new backup archive in the default repository

      prune
      : Remove old archives according to rules

      check
      : Check integrity of repo and latest archive

      compact
      : Save space in repo; runs automatically after prune

      list [args]
      : List recent backup archives, or contents of a specified archive. Arguments may
        be supplied to provide options to the list command, or specify a repository or
        a particular archive to list. By default, the options --consider-checkpoints and
        --last=10 are used, and the default repository is listed unless the --local
        option was used. No other commands may be used with list.

    Options

      --local [paths]
      : Backup to a local repo (i.e., on the present machine), for use when the regular
        repo is not available. Set the BORG_LOCAL_REPO environment variable to the path
        of the local repo. In this mode, a separate log file is used, and borg-go
        does not enforce running as root.

        The given paths are used as recursion roots instead of the defaults, but the
        configured pattern files are used to exclude files such as caches. Consider
        using the borg slashdot hack for these paths (recursion roots), as
        /path/is/stripped/./path/in/archive, e.g. /home/user/./Documents. If no paths
        are given, the default recursion roots are used to create a full backup to the
        local repo.

      --all
      : When running check, select all archives for check, rather than just the last 1
        with a name that matches the hostname. Additional selections may be made along
        with --all using the command arguments.

      -n, --dry-run
      : Run create and/or prune without changing the repo, to see what would be backed
        up or removed. The check and compact commands are not affected by the dry-run
        option, but compact will not run automatically after prune on a dry-run. This
        option also increases verbosity as in -v.

      -v, --verbose
      : Increase verbosity level of borg-go. Borg itself runs with --info verbosity.

    Examples

        borg-go create prune check
        borg-go --local ~/./Documents create
        borg-go --local list
        borg-go --local check --repair

    For config and setup, refer to the README file.
"""

borg-go() {

    # setup the environment: shell options, umask, traps, variables for mach_os, lognm,
    # borg_cmd, etc.
    # - ERR trap will cause exit for non-zero return statuses in this function
    _bg_setup

    # handle args; keep track of create/prune/check to preserve order
    local cmd_array=() cmd_args=() _dryrun _local _all rec_roots=()
    _bg_args "$@"
    shift $#

    # check for required scripts, running user, borg setup like BORG_REPO, etc.
    local repo_uri log_fn logging_dir
    _bg_pre-run

    # check for list command
    bg_list

    # Main ops
    local cmd cre_rc chk_rc
    for cmd in "${cmd_array[@]}"
    do
        case "$cmd" in
            ( create )
                bg_create
            ;;
            ( prune )
                bg_prune
                [[ ! -v _dryrun ]] \
                    && bg_compact
            ;;
            ( check )
                bg_check
            ;;
            ( compact )
                bg_compact
            ;;
        esac
    done

    _bg_post-run
}

_bg_setup() {

    # - exc_fn: executable path as called, which is likely a symlink
    exc_fn=$( basename -- "${BASH_SOURCE[0]}" )
    # - src_dir: resolved absolute canonical path to the script dir
    src_dir=$( command python3 -c "from os import path; print(path.dirname(path.realpath('${BASH_SOURCE[0]}')))" ) \
        || return
    # Configure some common variables, functions, shell options, traps
    # - e.g. set nounset, extglob, umask=027
    source "${src_dir}/bgo_env_setup.sh"
}

_bg_args() {

    # Parse arguments
    [[ $# -eq 0  || $1 == @(-h|--help|help) ]] \
        && { docsh -TDf borg-go; exit 0; }

    # TODO:
    # - allow chfile_sizes command

    while (( $# > 0 ))
    do
        case $1 in
            ( create | prune | check | compact )
                cmd_array+=( "$1" )
            ;;
            ( list )
                cmd_array+=( "$1" )
                cmd_args=( "${@:2}" )
                shift $#
                break
            ;;
            ( --local )
                _local=1
                (( ++_verb ))
                while [[ -v 2  && $2 != @(-*|create|prune|check|compact|list) ]]
                do
                    rec_roots+=( "$2" )
                    shift
                done
            ;;
            ( --all )
                _all=1
            ;;
            ( -n | --dry-run )
                _dryrun='--dry-run'
                (( ++_verb ))
            ;;
            ( -v | --verbose )
                (( ++_verb ))
            ;;
            ( -* )
                # args for a command
                if (( ${#cmd_array[*]} == 0 ))
                then
                    err_msg -d 3 "No command, but received option '$1'"
                    return

                elif (( ${#cmd_array[*]} > 1 ))
                then
                    err_msg -d 4 "More than one command, but received option '$1'"
                    return
                fi

                cmd_args=( "$@" )
                shift $#
                break
            ;;
            ( * )
                err_msg -d 2 "Unrecognized option: '$1'"
                return
            ;;
        esac
        shift
    done
}

_bg_pre-run() {

    trap 'return' ERR
    trap 'trap - return err' RETURN

    # Check for valid command(s)
    (( ${#cmd_array[*]} > 0 )) \
        || err_msg -d 2 "No valid commands received, stay frosty."

    # Borg environment variables
    # - Some variables are set in ~/.bashrc or launchd plist, and retained by sudo,
    #   per my sudoers policy: BORG_REPO, BORG_CONFIG_DIR, BORG_LOGGING_CONF, and
    #   BORG_EXIT_CODES.
    # - When running unencrypted locally or over a LAN, this is unset: BORG_PASSPHRASE
    # - Cache and security dirs should go in root's home when running under sudo.
    #   This is to prevent permissions problems when later running e.g. `borg info`
    #   as regular user.
    [[ -n ${BORG_CONFIG_DIR-} ]] \
        || export BORG_CONFIG_DIR=${lognm_home}/.config/borg
    export BORG_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/borg
    export BORG_SECURITY_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/borg/security

    if (( running_user != 0 )) \
        && [[ ${cmd_array[*]} != list  && ! -v _local ]]
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

    # Check for required scripts
    # - If PATH was reset (e.g. by sudo), borg-go may be harder to find, e.g. without
    #   setting up sudoers, or running from launchd/systemd/cron.
    # - However, we should still be able to find the supporting scripts in src_dir.
    # - Thus, borg-go should run fine as e.g. `sudo $(which borg-go)`.
    import_func -l bgo_chfile_sizes
    import_func -l bgo_ping_hc
    import_func -l bg_create
    bgo_scr_run --check bgo_prep_backupdir

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
        # - e.g. borg_logging.conf becomes borg_logging-dryrun.conf
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
        # - borg should append for this session, per borg_logging.conf, but bg_create
        #   does rotate the log files
        log_fn=$logging_dir/borg_log
    fi
    command touch "$log_fn"

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

    local post_msg="borg-go done"

    [[ -v cre_rc ]] && {
        (( cre_rc )) \
            && post_msg+=" (create status: $cre_rc)" \
            || post_msg+=" (create status: success)"
    }

    [[ -v chk_rc ]] && {
        (( chk_rc )) \
            && post_msg+=" (check status: $chk_rc)" \
            || post_msg+=" (check status: success)"
    }

    err_msg -d i "$post_msg"
}

bg_list() {

    # check for list
    if array_match cmd_array list
    then
        [[ ${#cmd_array[*]} == 1 ]] \
            || err_msg -d w "ignoring commands other than list"

        [[ -v 'cmd_args[*]' ]] \
            || cmd_args=( --consider-checkpoints --last=10 "$repo_uri" )

        vrb_msg 2 "running list ${cmd_args[*]}"

        BORG_LOGGING_CONF='' "$borg_cmd" list "${cmd_args[@]}"
        exit
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


# dependencies
_deps=( docsh err_msg vrb_msg physpath array_match run_vrb ignore_sigpipe )

if [[ $0 == "${BASH_SOURCE[0]}" ]]
then
    # Script was executed, not sourced
    trap 'exit' ERR

    # import dependencies
    # - import_func.sh should be symlinked somewhere on the PATH
    source import_func.sh
    import_func "${_deps[@]}"
    unset _deps

    # call main func
    # - NB, running as a_func || exit will *disable* any ERR trap set in a_func
    borg-go "$@"

else
    # This file is being sourced
    # - import_func should already be in the environment
    trap 'return' ERR

    import_func "${_deps[@]}"
    unset _deps
fi

