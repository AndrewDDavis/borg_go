# shellcheck shell=bash
bg_prune() {

    # Remove old backups according to schedule
    err_msg -d i "Calling borg prune${_dryrun:+ --dry-run}..."
    [[ -s $log_fn ]] \
        && printf '\n\n' >> "$log_fn"

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
        --info --show-rc "${pru_args[@]}" "$repo_uri" \
        || handle_borg_ec $?

    local pru_rc=$?

    if [[ -v _dryrun ]]
    then
        # report prune results on dry-run
        # - prevent wrapping for legibility
        # "$grep_cmd" ' (rule: ' "$log_fn"
        local w=$( tput cols )
        (( w -= 4 ))
        "$sed_cmd" -E '/ \(rule: / s/^.* INFO (.{'$w'}).*$/\1/' "$log_fn"

    elif (( pru_rc == 0 ))
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
        err_msg -d i "recording stats block"
        /bin/mv -f "${bp_stats_fn}.new" "$bp_stats_fn"

        hc_msg="borg-prune stats:"$'\n'
        hc_msg+=$( < "$bp_stats_fn" )
    else
        hc_msg="borg-prune stats block from log not as expected:"$'\n'
        hc_msg+="$bp_stats_fn.new"$'\n'
        err_msg -d w "$hc_msg"
    fi
}

bg_compact() {

    # Compact Repo
    # actually free repo disk space by compacting segments
    # - this is most useful after delete and prune operations
    err_msg -d i "Calling borg compact ..."
    [[ -s $log_fn ]] \
        && printf '\n\n' >> "$log_fn"

    run_vrb "$borg_cmd" compact \
        --threshold 1 --info --show-rc \
        "${com_args[@]}" "$repo_uri" \
        || handle_borg_ec $?
}
