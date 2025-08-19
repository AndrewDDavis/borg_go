#!/usr/bin/env bash

# This is borg-go, the main script to call borg using typical settings for this
# system.
#
# Inspired by the script in the official docs:
#   https://borgbackup.readthedocs.io/en/stable/quickstart.html#automating-backups
#
# by Andrew Davis (addavis@gmail.com)
# v0.2 (Dec 2023)

print_usage() {
cat << EOF

  borg-go
  -------
  This script runs Borg-Backup with the typical configuration and command options to
  create, prune, and check backups.

  Usage: borg-go [options] <command1 command2 ...>

  Commands

    create  -> create a new backup archive in the default repository
    prune   -> remove old archives according to rules
    check   -> check integrity of repo and latest archive
    compact -> save space in repo; runs automatically after prune
    list    -> list recent backup archives, or contents of a specified archive

  Options:
    -n | --dry-run -> run create and/or prune without changing the repo, to see what
                      would be backed up or removed. check and compact are not affected
                      by the dry-run option, but compact will not run automatically
                      after prune on a dry-run.

    -q | --quiet -> decrease info messages.

  For config and setup, see readme.

EOF
}

# Script options for shell
# - e = errexit : exit on non-zero pipeline, list, compound command
# - E = errtrace : trap on ERR is inherited by shell functions, subshells, etc.
set -eE

# - BASH_SOURCE and $0 likely refer to symlink
# - exc_fn and exc_dir refer to the executable path as called
BS0=${BASH_SOURCE[0]}
exc_fn=$( basename -- "$BS0" )
exc_dir=$( dirname -- "$BS0" )

# - src_dir refers to the resolved absolute canonical path to the script dir
src_dir=$( python3 -c "import os.path as osp; print(osp.dirname(osp.realpath('$BS0')))" )


# Configure some common variables, functions, and shell options (e.g. globbing rules)
source "$src_dir/bgo_functions.sh"


# Parse arguments
[[ $# -eq 0  || $1 == @(-h|--help|help) ]] \
    && { print_usage; exit 0; }

# - keep track of create/prune/check to preserve order
cmd_array=()

while (( $# > 0 ))
do
    case $1 in
        ( create | prune | check | compact )
            cmd_array+=( $1 )
        ;;
        ( list )
            BORG_LOGGING_CONF='' borg list "${@:2}"
            exit 0
        ;;
        ( -n | --dry-run )
            dry_run="--dry-run"
        ;;
        ( -q | --quiet )
            quiet=true
        ;;
        ( * )
            raise 2 "Unrecognized option: '$1'"
        ;;
    esac
    shift
done


# Check for valid command(s)
(( "${#cmd_array[@]}" == 0 )) \
    && raise w "No valid commands received, stay frosty."

# Check for root
# - See the ReadMe for discussion on the running user for borg.
[[ $( id -u ) -eq 0 ]] \
    || raise 2 "root or sudo required."


# Environment variables
# - set in user ~/.bashrc or launchd plist: BORG_REPO, BORG_CONFIG_DIR,
#   BORG_LOGGING_CONF, and BORG_EXIT_CODES
# - these are retained by sudo, per my sudoers policy.
# - unset, when running unencrypted locally or over a LAN: BORG_PASSPHRASE
# - cache and security should go in root's home if running with `sudo`. This is to
#   prevent permissions problems when later running e.g. `borg info` as regular user.
export BORG_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/borg
export BORG_SECURITY_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/borg/security

# If PATH was reset, borg-go may be harder to find, e.g. without setting up sudoers,
# or running from launchd/systemd/cron.
# - However, we should still be able to find the supporting scripts in src_dir.
# - Thus, borg-go should run fine as e.g. `sudo $(which borg-go)`.
# - no longer used: $PATH != *"$exc_dir"*
if [[ -z $(command -v borg-go) && ${quiet:-} != true ]]
then
    print_msg "borg-go dir is not on path, consider using $src_dir/bgo_link.sh"
fi

# Other required scripts should be in src_dir
scr_chk() {
    [[ -x "${src_dir}/${1}.sh" ]] \
        || raise 9 "no executable found at ${src_dir}/${1}.sh"
}

scr_chk bgo_chfile_sizes
scr_chk bgo_ping_hc
scr_chk bgo_prep_backup

[[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] \
    && scr_chk bgo_check_mount


# Ensure log dir and file exists
logging_dir=$BORG_CONFIG_DIR/log
[[ -d $logging_dir ]] \
    || /bin/mkdir -p "$logging_dir"

if [[ -n ${dry_run-} ]]
then
    # - use a separate log file on dry-runs, and overwrite every time
    # - e.g. borg_logging.conf becomes borg_logging-dryrun.conf
    BORG_LOGGING_CONF=${BORG_LOGGING_CONF/%.conf/-dryrun.conf}
    log_fn=$logging_dir/borg_dryrun_log.txt
else
    # - borg should append for this session, per borg_logging.conf, but bg_create does
    #   rotate the log files
    log_fn=$logging_dir/borg_log.txt
fi
touch "$log_fn"


main() {

    ### --- Pre-run commands ---
    # mount repo if needed (erikson, mendeleev)
    [[ -n ${BORG_MNT_REQD-}  && $BORG_MNT_REQD != 0 ]] && {
        print_msg "Mounting backup repo"
        "${src_dir}"/bgo_check_mount.sh
    }

    # otherwise, check that ssh connection is possible
    [[ ${BORG_REPO:0:6} == "ssh://" ]] && {
        _rem=${BORG_REPO:6}
        _rem=${_rem%%/*}
        ssh "$_rem" true
    }


    ### --- Main operations ---
    for cmd in "${cmd_array[@]}"
    do
        case "$cmd" in
            ( create )
                bg_create
            ;;
            ( prune )
                run_prune && {
                    [[ -z ${dry_run-} ]] \
                        && run_compact
                }
            ;;
            ( check )
                run_check
            ;;
            ( compact )
                run_compact
            ;;
        esac
    done


    ### --- Post-run commands ---
    # unmount
    [[ -n ${BORG_MNT_REQD-} && $BORG_MNT_REQD != 0 ]] && {
        print_msg "Unmounting backup repo"
        "${src_dir}"/bgo_check_mount.sh -u
    }

    # chown log files owned by root to user login name, if running under sudo
    # - should only be necessary for newly created files
    def_lognm    # from bgo_functions: sets lognm, lognm_group, lognm_home

    command find "$BORG_CONFIG_DIR" \
        \( \
            -name 'borg_log.txt*' \
            -o -name 'borg_dryrun_log.txt' \
            -o -name 'borg_log_chfile*.txt' \
            -o -name 'borg_log_*-stats.txt' \
            -o -name 'borg-go_[ls]*d_out.txt*' \
        \) \
        -user "$( id -un 0 )" \
        -exec chown "$lognm":"$lognm_group" '{}' \;

    print_msg "borg-go done."
}


bg_create() (

    ### --- Create Backup Archive ---
    # Backup e.g. system config and user files into an archive named after this machine
    local ping_msg

    print_msg "Starting backup ..."
    "${src_dir}"/bgo_ping_hc.sh start -m "borg${dry_run:+" ${dry_run}"} cmds: ${cmd_array[*]}"

    print_msg "- running pre-backup script"
    "${src_dir}"/bgo_prep_backup.sh

    if [[ -n ${dry_run-} ]]
    then
        # dry-run affects item flags in log
        filters='x-'
    else
        filters='AMCE'
    fi

    # include all patterns and recursion roots files in alphanum order
    # - NB, nullglob is in effect
    local bc_pats=() rec_roots=()

    for fn in "$BORG_CONFIG_DIR"/borg_{recursion_roots,patterns}*.txt
    do
        [[ -s $fn ]] \
            && bc_pats+=( --patterns-from "$fn" )

        # report the recursion roots in effect
        mapfile -t -O"${#rec_roots[*]}" rec_roots < \
            <( command grep -hE '^R ' "$fn" || true )
    done

    if (( ${#bc_pats[*]} == 0 ))
    then
        raise 2 "Empty patterns and recursion roots (bc_pats)."

    elif (( ${#rec_roots[*]} == 0 ))
    then
        raise 3 "No recursion roots found in pattern files"
    fi

    if [[ -z ${dry_run-} ]]
    then
        rotate_logs
    fi

    # Borg call
    print_msg "- calling borg create${dry_run:+" ${dry_run}"} with recursion roots:"
    printf >&2 '    '
    printf >&2 '%s,  ' "${rec_roots[@]:0:${#rec_roots[*]}-1}"
    printf >&2 '%s\n' "${rec_roots[@]:(-1)}"

    # - add -p for progress
    # - compression is lz4 by default
    # - using || to catch exit code 1, which borg uses for warnings
    #   note handle_borg_ec might add a warning to ping_msg

    bc_opts=( ${dry_run-} )
    bc_opts+=( --list --filter "$filters" --stats )               # list items backed up matching filters, and show stats
    bc_opts+=( --info --show-rc )                                 # be verbose, log borg's return code
    bc_opts+=( --exclude-caches --exclude-if-present .nobackup )  # exclude dirs containing CACHEDIR.TAG or .nobackup
    bc_opts+=( --one-file-system )                                # do not backup mount-points

    borg create "${bc_opts[@]}" "${bc_pats[@]}" ::'{hostname}-{now:%Y-%m-%dT%H.%M.%S}'  \
        || handle_borg_ec $?


    if [[ -n ${dry_run-} ]]
    then
        # stats and changed files only supported without dry-run
        ping_msg+="no stats from create --dry-run"

    else
        # record file sizes for backed-up files
        print_msg "- recording sizes of changed files"
        "${src_dir}"/bgo_chfile_sizes.sh

        # set aside stats block from log to prevent overwriting
        bc_stats_fn="$logging_dir/borg_log_create-stats.txt"
        grep -B 6 -A 10 'INFO Duration' "$log_fn" > "$bc_stats_fn.new"

        if [[ $(grep -c '^' "$bc_stats_fn.new") -eq 17 ]]
        then
            print_msg "- recording stats block"
            /bin/mv -f "$bc_stats_fn.new" "$bc_stats_fn"
            ping_msg+="borg-create stats:"$'\n'
            ping_msg+=$(< "$bc_stats_fn")

        else
            ping_msg+="borg-create stats block from log not as expected: $bc_stats_fn.new"
            print_msg WARNING "$ping_msg"
        fi
    fi

    # signal successful backup
    "${src_dir}"/bgo_ping_hc.sh success -m "$ping_msg"
)

run_prune() {

    ### --- Prune Backup Archives ---
    # Remove old backups according to schedule
    local ping_msg

    print_msg "Starting prune ..."

    # borg command
    print_msg "- calling borg prune${dry_run:+" ${dry_run}"}"
    # - The '{hostname}-' prefix limits the prune operation to the archives associated
    #   with the present machine.
    # - N.B. the keep rules do not operate exactly as you may expect, because intervals
    #   in which there are no backups are not counted. E.g., if you only did 7 backups
    #   in the last year, and they were all on different days, then --keep-daily 7 would
    #   keep all those backups for the last year, not just the ones in the past week.
    #   Or, e.g. if you only backup daily, and use --keep-hourly 24, the last 24 days of
    #   backups will be kept. The keep-within rules are more like this, but not
    #   exactly...
    # - From the docs:
    #     + The --keep-within option takes an argument of the form “<int><char>”, where
    #       char is “H”, “d”, “w”, “m”, “y”. For example, --keep-within 2d means to keep
    #       all archives that were created within the past 48 hours.
    #     + The archives kept with this option do not count towards the totals specified
    #       by any other options.
    #     + E.g., --keep-daily 7 means to keep the latest backup on each day, up to 7
    #       most recent days with backups (days without backups do not count).
    # - If any rule is not fully satisfied, the earliest backup is retained.
    # - Weeks go from Monday to Sunday, so weekly backups may keep e.g. a Tuesday and a
    #   Sunday archive if that's all it has to choose from.
    # - See the docs for examples, but the finer details probably don't matter to us:
    #   https://borgbackup.readthedocs.io/en/stable/usage/prune.html
    # - The following options should keep every archive within the last 14 days, and
    #   weekly archives for 2 weeks that have a backup before that, then similarly for 6
    #   monthly archives, and 3 yearly archives.

    borg prune ${dry_run-} --list --stats -a '{hostname}-*' \
               --keep-within 14d                            \
               --keep-weekly 2                              \
               --keep-monthly 6                             \
               --keep-yearly 3                              \
               --info --show-rc ::

    if [[ -n ${dry_run-} ]]
    then
        # stats only supported without dry-run
        ping_msg="no stats from prune --dry-run"$'\n'

    else
        # set aside stats block from log to prevent overwriting
        bp_stats_fn="$logging_dir/borg_log_prune-stats.txt"
        grep -B 2 -A 5 'INFO Deleted data' "$log_fn" > "${bp_stats_fn}.new"

        if [[ $(grep -c '^' "${bp_stats_fn}.new") -eq 8 ]]
        then
            print_msg "- recording stats block"
            /bin/mv -f "${bp_stats_fn}.new" "$bp_stats_fn"
            ping_msg="borg-prune stats:"$'\n'
            ping_msg+=$(< "$bp_stats_fn")
        else
            ping_msg="borg-prune stats block from log not as expected:"$'\n'
            ping_msg+="$bp_stats_fn.new"$'\n'
            print_msg WARNING "$ping_msg"
        fi
    fi

    # signal successful prune
    "${src_dir}"/bgo_ping_hc.sh success -m "$ping_msg"
}

run_check() {

    ### --- Check Repo and Archive(s) ---
    # Examine backup repo and most recent archive to ensure validity
    print_msg "Starting check ..."

    borg check \
        --last 1 -a '{hostname}-*' \
        --info --show-rc ::
    # --progress ?
}

run_compact() {

    ### --- Compact Repo ---
    # actually free repo disk space by compacting segments
    # - this is most useful after delete and prune operations
    print_msg "Starting compact ..."

    borg compact \
        --threshold 1 \
        --info --show-rc ::
}

rotate_logs() {

    # Rotate log file
    if [[ -n $(command -v savelog) ]]
    then
        # use savelog to rotate 7 files, compress, preserve perms, and touch new
        savelog -c 7 -ntp "$log_fn"
    else
        _rotate_one() {
            local -i i=$1
            local -i j=i+1

            # check log file exists with non-zero size
            if [[ -s ${log_fn}.$i ]]
            then
                /bin/mv -f "${log_fn}.$i" "${log_fn}.$j" && {
                    gzip -f "${log_fn}.$j"
                }

            elif [[ -s ${log_fn}.$i.gz ]]
            then
                /bin/mv -f "${log_fn}.$i.gz" "${log_fn}.$j.gz"
            else
                return 0
            fi
        }

        # move older files, starting with the oldest
        local -i k
        for k in 6 5 4 3 2 1 0
        do
            _rotate_one $k
        done

        # move most recent file to .0
        # - use cp to preserve ownership and file mode of log_fn
        [[ -s $log_fn ]] && /bin/cp -pf "$log_fn" "${log_fn}.0"

        printf '' > "$log_fn"
    fi
}

handle_borg_ec() {

    # Handle non-zero exit codes from borg
    # - borg exits with ec=1 or 100-127 for warnings, which shouldn't
    #   bring down the whole script, but should be reported
    local -i ec=$1
    shift

    if (( ec == 1 || ( ec > 99 && ec < 128 ) ))
    then
        # relay borg warning
        ping_msg="${FUNCNAME[1]}(): borg exited with code $ec; WARNINGs from borg_log.txt:"$'\n'
        ping_msg+=$( command grep WARNING "$log_fn" )$'\n'
        print_msg WARNING "$ping_msg"

    else
        # trigger the trap error handling
        ( exit $ec )
    fi
}


# Now that functions are defined, run main()
main
