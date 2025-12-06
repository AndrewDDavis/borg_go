# shellcheck shell=bash
bg_check() {

    # Check repo and archive(s)
    # - examine backup repo and most recent archive to ensure validity
    local arch_sel=( --last 1 -a '{hostname}-*' )
    [[ -v _chk_all ]] \
        && arch_sel=()

    err_msg -d i "Calling borg check ${arch_sel[*]:0:2}..."
    [[ -s $log_fn ]] \
        && printf '\n\n' >> "$log_fn"
    chk_rc=0

    run_vrb "$borg_cmd" check \
        "${arch_sel[@]}" \
        --info --progress --show-rc \
        "${chk_args[@]}" "$repo_uri" \
        || handle_borg_ec $?
}
