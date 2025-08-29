# functions for main backup operations, imported by borg-go

# shellcheck shell=bash

bg_create() {

    trap 'return' ERR
    trap 'trap - return err' RETURN

    # Create Backup Archive
    # - e.g., backup system config and user files into an archive named after this machine
    err_msg -d i "Starting backup ..."

    if [[ ! -v _dryrun ]]
    then
        bgo_ping_hc start -m "borg${_dryrun:+ --dry-run} cmds: ${cmd_array[*]}"

        err_msg -d i "running pre-backup script"
        bgo_scr_run bgo_prep_backupdir

        rotate_logs
        cre_rc=0
    fi

    # prepare borg-create command line
    local bc_args=()
    _bgc_cmdln

    # - using || to catch borg warning exit codes
    # - NB, handle_borg_ec might add a warning to hc_msg
    local hc_msg
    run_vrb "$borg_cmd" create "${bc_args[@]}" \
        || handle_borg_ec $?

    if [[ ! -v _dryrun ]]
    then
        # record file sizes for backed-up files
        _bgc_stats

        # signal successful backup
        bgo_ping_hc success -m "$hc_msg"
    fi
}

_bgc_cmdln() {

    # patterns and recursion roots
    local bc_pats=() bc_rrs=()
    if [[ ! -v 'rec_roots[*]' ]]
    then
        # include all patterns and recursion roots files in alphanum order
        # - NB, nullglob is in effect
        for fn in "$BORG_CONFIG_DIR"/borg_{recursion_roots,patterns}*.txt
        do
            if [[ -s $fn ]]
            then
                bc_pats+=( --patterns-from "$fn" )

                # report the recursion roots in effect
                mapfile -t -O"${#rec_roots[*]}" rec_roots < \
                    <( "$grep_cmd" -hE '^R ' "$fn" || true )
            fi
        done

        if (( ${#bc_pats[*]} == 0 ))
        then
            err_msg -d 2 "Empty patterns and recursion roots (bc_pats)."
            return

        elif (( ${#rec_roots[*]} == 0 ))
        then
            err_msg -d 3 "No recursion roots found in pattern files"
            return
        fi

        err_msg -d i "- calling borg create${_dryrun:+ --dry-run} with recursion roots:"
        printf >&2 '    '
        printf >&2 '%s,  ' "${rec_roots[@]:0:${#rec_roots[*]}-1}"
        printf >&2 '%s\n' "${rec_roots[@]:(-1)}"

    else
        # custom rec_roots for --local
        bc_rrs=( "${rec_roots[@]}" )

        for fn in "$BORG_CONFIG_DIR"/borg_patterns*.txt
        do
            [[ -s $fn ]] \
                && bc_pats+=( --patterns-from "$fn" )
        done
    fi

    # item flags for log
    local filters='--filter='
    if [[ -v _dryrun ]]
    then
        # NB, AME don't apply to dry-run, only x and - are respected
        filters+='x'
    else
        filters+='AMCE'
    fi

    # borg-create options
    # - add -p for progress
    # - compression is lz4 by default
    local bc_opts=( "${_dryrun:---stats}" --list "$filters" )   # list items backed up matching filters, and show stats
    bc_opts+=( --info --show-rc )                                 # be verbose, log borg's return code
    bc_opts+=( --exclude-caches --exclude-if-present .nobackup )  # exclude dirs containing CACHEDIR.TAG or .nobackup
    bc_opts+=( --one-file-system )                                # do not backup mount-points

    # repo and archive name
    local ra_str='{hostname}-{now:%FT%T%Z}'
    if [[ ${repo_uri:(-2)} == '::' ]]
    then
        ra_str=${repo_uri}${ra_str}
    else
        ra_str=${repo_uri}::${ra_str}
    fi

    bc_args=( "${bc_opts[@]}" "${cmd_args[@]}" "${bc_pats[@]}" "$ra_str" "${bc_rrs[@]}" )
}

_bgc_stats() {

    trap 'return' ERR
    trap 'trap - err return' RETURN

    err_msg -d i "- recording sizes of changed files"
    bgo_chfile_sizes

    # set aside stats block from log to prevent overwriting
    local bc_stats_fn=${log_fn}_create-stats
    "$grep_cmd" -B 6 -A 10 'INFO Duration' "$log_fn" > "$bc_stats_fn.new"

    if [[ $( "$grep_cmd" -c '^' "$bc_stats_fn.new" ) -eq 17 ]]
    then
        err_msg -d i "- recording stats block"
        /bin/mv -f "$bc_stats_fn.new" "$bc_stats_fn"
        hc_msg+="borg-create stats:"$'\n'
        hc_msg+=$( < "$bc_stats_fn" )

    else
        hc_msg+="borg-create stats block from log not as expected: $bc_stats_fn.new"
        err_msg -d w "$hc_msg"
    fi
}

bg_prune() {

    # Remove old backups according to schedule
    err_msg -d i "Calling borg prune${_dryrun:+ --dry-run}..."
    printf '\n\n' >> "$log_fn"

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

    run_vrb "$borg_cmd" prune -a '{hostname}-*' \
        --keep-within 14d --keep-weekly 2 \
        --keep-monthly 6 --keep-yearly 3 \
        "${_dryrun:---stats}" --list \
        --info --show-rc "${cmd_args[@]}" "$repo_uri" \
        || handle_borg_ec $?

    local pru_rc=$?
    if (( pru_rc == 0 )) && [[ ! -v _dryrun ]]
    then
        # note prune stats
        local hc_msg
        _bgp_stats

        # signal successful prune
        bgo_ping_hc success -m "$hc_msg"
    fi

    return $pru_rc
}

_bgp_stats() {

    # set aside stats block from log to prevent overwriting
    local bp_stats_fn=${log_fn}_prune-stats
    "$grep_cmd" -B 2 -A 5 'INFO Deleted data' "$log_fn" > "${bp_stats_fn}.new"

    if [[ $( "$grep_cmd" -c '^' "${bp_stats_fn}.new" ) -eq 8 ]]
    then
        err_msg -d i "- recording stats block"
        /bin/mv -f "${bp_stats_fn}.new" "$bp_stats_fn"

        hc_msg="borg-prune stats:"$'\n'
        hc_msg+=$(< "$bp_stats_fn")
    else
        hc_msg="borg-prune stats block from log not as expected:"$'\n'
        hc_msg+="$bp_stats_fn.new"$'\n'
        err_msg -d w "$hc_msg"
    fi
}

bg_check() {

    # Check repo and archive(s)
    # - examine backup repo and most recent archive to ensure validity
    local arch_sel=( --last 1 -a '{hostname}-*' )
    [[ -v _all ]] \
        && arch_sel=()

    err_msg -d i "Calling borg check ${arch_sel[*]:0:2}..."
    printf '\n\n' >> "$log_fn"
    chk_rc=0

    run_vrb "$borg_cmd" check \
        "${arch_sel[@]}" \
        --info --progress --show-rc \
        "${cmd_args[@]}" "$repo_uri" \
        || handle_borg_ec $?
}

bg_compact() {

    # Compact Repo
    # actually free repo disk space by compacting segments
    # - this is most useful after delete and prune operations
    err_msg -d i "Calling borg compact ..."
    printf '\n\n' >> "$log_fn"

    run_vrb "$borg_cmd" compact \
        --threshold 1 --info --show-rc \
        "${cmd_args[@]}" "$repo_uri" \
        || handle_borg_ec $?
}

rotate_logs() {

    # Rotate log file
    if [[ -n $( command -v savelog ) ]]
    then
        # use savelog to rotate 7 files, compress, preserve perms, and touch new
        command savelog -c 7 -ntp "$log_fn"

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
        # - cp -p preserves ownership and file mode
        [[ -s $log_fn ]] \
            && /bin/cp -pf "$log_fn" "${log_fn}.0"

        printf '' > "$log_fn"
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
