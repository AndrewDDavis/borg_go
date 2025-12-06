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

        rotate_logs "$log_fn"
        cre_rc=0
    fi

    # assemble and run the borg-create command line
    # - using || to catch borg warning exit codes
    # - NB, handle_borg_ec might add a warning to hc_msg
    local bc_args=()
    _bgc_args

    local hc_msg
    run_vrb "$borg_cmd" create "${bc_args[@]}" \
        || handle_borg_ec $?

    # report termination status to user
    local term_ln
    term_ln=$( "$tail_cmd" -n1 "$log_fn" | "$grep_cmd" 'INFO terminating' ) \
        && vrb_msg 2 "$term_ln"

    if [[ ! -v _dryrun ]]
    then
        # record file sizes for backed-up files
        _bgc_stats

        # signal successful backup
        bgo_ping_hc success -m "$hc_msg"
    fi
}

_bgc_args() {

    # assemble the arguments for borg create
    trap 'return' ERR
    trap 'trap - return err' RETURN

    # define pattern and recursion root filenames
    local pat_fn_args=()

    if [[ ! -v 'rr_paths[*]' ]]
    then
        # include all pattern and recursion root files in alphanum order
        _bgc_rrpats
    else
        # use rec-root paths from cmdline, along with configured patterns
        _bgc_onlypats
    fi

    # define other command options
    # - add -p for progress
    # - compression is lz4 by default
    local bc_opts=()
    _bgc_opts

    # repo and archive name
    local ra_str='{hostname}-{now:%FT%T%Z}'

    if [[ ${repo_uri:(-2)} == '::' ]]
    then
        ra_str=${repo_uri}${ra_str}
    else
        ra_str=${repo_uri}::${ra_str}
    fi

    # NB, the first matching pattern wins, so command-line patterns should override
    # the configured ones if there is a conflict.
    bc_args=( "${bc_opts[@]}" "${pat_fn_args[@]}" "${cre_args[@]}" "$ra_str" "${rr_paths[@]}" )
}

_bgc_opts() {

    # define borg-create options
    trap 'return' ERR
    trap 'trap - return err' RETURN

    # - show stats and list items backed up
    bc_opts=( "${_dryrun:---stats}" --list )

    # - only log items with the some status chars
    # - A = new file added, M = modified file, C = file changed during backup, E = read error
    # - NB, AME don't apply to dry-run, only x (excluded) and - (dry-run) are respected
    # - refer: https://borgbackup.readthedocs.io/en/stable/usage/create.html#item-flags
    if [[ -v _dryrun ]]
    then
        bc_opts+=( '--filter=x' )
    else
        bc_opts+=( '--filter=AMCE' )
    fi

    # be verbose, log borg's return code
    bc_opts+=( --info --show-rc )

    # exclude dirs containing CACHEDIR.TAG or .nobackup
    bc_opts+=( --exclude-caches --exclude-if-present .nobackup )

    # do not backup mount-points
    bc_opts+=( --one-file-system )
}

_bgc_rrpats() {

    # define and check pattern and recursion root filenames
    trap 'return' ERR
    trap 'trap - return err' RETURN

    local fn rr_pats=()
    while IFS='' read -rd '' fn <&3
    do
        if [[ -s $fn ]]
        then
            pat_fn_args+=( --patterns-from "$fn" )

            # note whether fn contains a recursion root pattern
            mapfile -t -O"${#rr_pats[*]}" rr_pats < \
                <( "$grep_cmd" -hE '^R ' "$fn" || true )
        fi

    done 3< <( "$find_cmd" "$BORG_CONFIG_DIR" -maxdepth 1 -regextype egrep \
                    -regex '.*/(patterns|rec_roots)[^.]*' -print0 )


    if (( ${#pat_fn_args[*]} == 0 ))
    then
        err_msg -d 2 "No pattern or recursion root files found in BORG_CONFIG_DIR."

    elif (( ${#rr_pats[*]} == 0 ))
    then
        err_msg -d 3 "No recursion root patterns found in pattern files."
    fi

    # report rec roots to the user
    err_msg -d i "calling borg create${_dryrun:+ --dry-run} with recursion roots:"
    printf >&2 '    '
    printf >&2 '%s,  ' "${rr_pats[@]:0:${#rr_pats[*]}-1}"
    printf >&2 '%s\n' "${rr_pats[@]:(-1)}"
}

_bgc_onlypats() {

    # define filenames from custom rec-root paths and configured patterns
    trap 'return' ERR
    trap 'trap - return err' RETURN

    local fn
    for fn in "${rr_paths[@]}"
    do
        [[ -r $fn ]] ||
            err_msg -d 3 "Recursion root path not found: '$fn'"
    done

    while IFS='' read -rd '' fn <&3
    do
        [[ -s $fn ]] \
            && pat_fn_args+=( --patterns-from "$fn" )

    done 3< <( "$find_cmd" "$BORG_CONFIG_DIR" -maxdepth 1 -regextype egrep \
                    -regex '.*/patterns[^.]*' -print0 )
}

_bgc_stats() {

    trap 'return' ERR
    trap 'trap - err return' RETURN

    err_msg -d i "recording sizes of changed files"
    bgo_chfile_sizes

    # set aside stats block from log to prevent overwriting
    local bc_stats_fn=${log_fn}_create-stats
    "$grep_cmd" -B 6 -A 10 'INFO Duration' "$log_fn" > "${bc_stats_fn}.new"

    # expect info block with 17 lines
    if [[ $( "$grep_cmd" -c '^' "${bc_stats_fn}.new" ) -eq 17 ]]
    then
        err_msg -d i "recording stats block"
        /bin/mv -f "${bc_stats_fn}.new" "$bc_stats_fn"
        hc_msg+="borg-create stats:"$'\n'
        hc_msg+=$( < "$bc_stats_fn" )

    else
        hc_msg+="borg-create stats block from log not as expected: ${bc_stats_fn}.new"
        err_msg -d w "$hc_msg"
    fi
}
