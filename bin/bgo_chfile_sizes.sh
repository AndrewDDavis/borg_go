# find backed-up files from the latest backup archive process from borg
# and sort by size
#
# - reads and writes to ~/.config/borg, in the logged in user's home
# - requires recent borgmatic backup run with --files, or recent borg
#   backup run with --info --list --filter=AME...
#
# v0.2 (Aug 2025) by Andrew Davis (addavis@gmail.com)

# shellcheck shell=bash

bgo_chfile_sizes() {

    trap 'return' ERR
    trap 'trap - err return' RETURN

    # log_fn and logging_dir were set in _bg_pre-run
    # - log_fn is e.g. $logging_dir/borg_log or $logging_dir/borg_dryrun_log
    [[ -r $log_fn ]] \
        || err_msg -d 3 "could not read log file: '$log_fn'"

    local chf_fn=${log_fn}_chfiles
    local errf_fn=${log_fn}_errfiles
    local du_out_fn=${log_fn}_chfile_sizes
    local du_fails_fn=${log_fn}_chfile_fails


    # check for any error files
    "$sed_cmd" -En 's/^.*INFO E (.*)/\1/ p' "$log_fn" > "${errf_fn}.new"

    # if ! "$grep_cmd" -qc '^' "${errf_fn}.new"
    if [[ $( file "${errf_fn}.new" ) == *': empty' ]]
    then
        # no errors, as expected
        /bin/rm -f "${errf_fn}.new"

    else
        /bin/mv -f "${errf_fn}.new" "$errf_fn"
        (( running_user == 0 )) \
            && "$chown_cmd" "$lognm":"$lognm_group" "$errf_fn"
        err_msg -d w "Error files found, see ${errf_fn}:"
        command head "$errf_fn"
    fi


    # extract file paths of changed files from the log
    "$sed_cmd" -En 's/^.*INFO [AMC] (.*)/\1/ p' "$log_fn" > "${chf_fn}.new"
    (( running_user == 0 )) \
        && "$chown_cmd" "$lognm":"$lognm_group" "${chf_fn}.new"

    local n_files
    if n_files=$( "$grep_cmd" -c '^' "${chf_fn}.new" )
    then
        /bin/mv -f "${chf_fn}.new" "$chf_fn"
    else
        /bin/rm -f "${chf_fn}.new"
        err_msg -d w "no changed files found in log"
        return
    fi


    # compute file sizes for changed files
    # implementation notes:
    # - du's "cannot access" messages/errors occur for moved/deleted files
    # - the tr hack works as long as there are no newlines in filenames (BSD du does
    #   not have --files0-from)
    # - also, du doesn't read from stdin under BSD, so getting the total (-c) is tricky
    # - I would like to simply use `du -hsc $(< $chf_fn)` but that produces argument
    #   list too long for a large number of files
    # - it would be pretty standard to use a while-read loop on chf_fn, with the du
    #   command in the loop, but this really drags when there are many new files; it
    #   takes minutes when it should take seconds.
    # - using xargs -0 instead, wrapping the du call in a function to handle the || and
    #   still allow multiple arguments from xargs
    # - need to export variables to be available in the bash child process
    # - consider using e.g. -P4 to parallelize du commands;
    #   echo 1 2 3 | xargs -n1 -P10 bash -c 'echo_var "$@"' _
    du_call() {

        command du -hs -- "$@" >>"${du_out_fn}.new" 2>>"${du_fails_fn}.new" \
            || true
    }

    export -f du_call
    export du_out_fn du_fails_fn

    : > "${du_out_fn}.new"
    : > "${du_fails_fn}.new"
    < "$chf_fn" tr '\n' '\0' \
        | command xargs -0 bash -c 'du_call "$@"' _

    unset -f du_call
    declare +x du_out_fn du_fails_fn


    # ensure du output was as expected
    local n_sizes
    n_sizes=$( "$grep_cmd" -c '^' "${du_out_fn}.new" ) \
        || { err_msg -d 2 "no sizes found by du: '$PWD/${du_out_fn}.new'"; exit; }

    # chown and move log file
    (( running_user == 0 )) \
        && "$chown_cmd" "$lognm":"$lognm_group" "${du_out_fn}.new"
    /bin/mv -f "${du_out_fn}.new" "$du_out_fn"

    # if [[ -s "${du_fails_fn}.new" ]]
    if [[ $( file "${du_fails_fn}.new" ) == *': empty' ]]
    then
        /bin/rm -f "${du_fails_fn}.new" "$du_fails_fn"  # rm if empty
    else
        /bin/mv -f "${du_fails_fn}.new" "$du_fails_fn"
    fi

    err_msg -d i "Files and sizes output to $du_out_fn"
    err_msg -d i "Found $n_files filenames, reported sizes on $n_sizes"

    # output top 12 files sorted by size
    # -h handles human-readable chars for K, M, G, etc
    # sed prepends spaces to each line; head sends sigpipe to sort (can cause exit 141)
    err_msg -d i "Largest 12:"
    command sort -rh "$du_out_fn" \
        | command head -n12 \
        | "$sed_cmd" 's/^/    /' \
        || ignore_sigpipe $?
}



# vvv Below re-written as a function to be imported in borg-go

# # Configure some common variables, shell options, traps
# src_dir=$( command python3 -c "import os; print(os.path.dirname(os.path.realpath('${BASH_SOURCE[0]}')))" )
# builtin source "$src_dir/bgo_env_setup.sh"


# # requires root to reliably stat all files (not for --local)
# [[ $( command id -u ) -eq 0 ]] \
#     || err_msg -d 2 "root or sudo required."

# # find config dir based on logged-in user name (when running with sudo)
# # - lognm variables come from bgo_env_setup
# [[ -z ${BORG_CONFIG_DIR-} ]] \
#     && BORG_CONFIG_DIR="$lognm_home/.config/borg"

# builtin cd "$BORG_CONFIG_DIR" \
#     || err_msg -d 2 "could not cd to config dir: '$BORG_CONFIG_DIR'"

# borg_logfile=log/borg_log    # not for --local
# chf_fn=log/borg_log_chfiles
# errf_fn=log/borg_errfiles
# du_fn=log/borg_log_chfile_sizes
# du_fails=${du_fn/sizes/fails}

# [[ -r $borg_logfile ]] \
#     || err_msg -d 2 "could not read logfile: '$borg_logfile'"

# # check for any error files
# "$sed_cmd" -En 's/^.*INFO E (.*)/\1/ p' "$borg_logfile" > "${errf_fn}.new"

# # vvv [[ -s errf_fn.new ]]
# if ! "$grep_cmd" -qc '^' "${errf_fn}.new"
# then
#     # no errors, as expected
#     /bin/rm -f "${errf_fn}.new"

# else
#     /bin/mv -f "${errf_fn}.new" "$errf_fn"
#     "$chown_cmd" "$lognm":"$lognm_group" "$errf_fn"
#     err_msg -d w "Error files found, see $errf_fn:"
#     command head "$errf_fn"
# fi

# # parse log file to extract only file paths of changed files
# "$sed_cmd" -En 's/^.*INFO [AMC] (.*)/\1/ p' "$borg_logfile" > "${chf_fn}.new"

# # chown log file
# "$chown_cmd" "$lognm":"$lognm_group" "${chf_fn}.new"

# if ! n_files=$( "$grep_cmd" -c '^' "${chf_fn}.new" )
# then
#     /bin/rm -f "${chf_fn}.new"
#     { err_msg -d w "no filenames found in log"; exit; }
# fi

# /bin/mv -f "${chf_fn}.new" "$chf_fn"


# # compute file sizes for changed files
# # - du's "cannot access" messages/errors occur for moved/deleted files
# # - implementation notes:
# #     + this works as long as there are no newlines in filenames (BSD du does not have
# #       --files0-from)
# #     + would like to do `du -hsc $(< $chf_fn)` but produces argument list too long for
# #       a large number of files
# #     + also, du doesn't read from stdin under BSD, so getting the total (-c) is tricky
# >"${du_fn}.new"
# >"${du_fails}.new"

# # while IFS='' read -r fn
# # do
# #     du -hs -- "$fn" >>"${du_fn}.new" 2>>"${du_fails}.new" || {
# #         true
# #     }
# # done <"$chf_fn"

# # When there are many new files, the above loop really drags: takes minutes when it
# # should take seconds.
# # - use xargs -0 instead, wrapping the du call in a function to handle the || and still
# #   allow multiple arguments from xargs
# # - need to export variables to be available to the bash command call
# du_call() {

#     command du -hs -- "$@" >>"${du_fn}.new" 2>>"${du_fails}.new" \
#         || true
# }

# export -f du_call
# export du_fn du_fails

# <"$chf_fn" tr '\n' '\0' \
#     | command xargs -0 bash -c 'du_call "$@"' _


# # ensure du output was as expected
# n_sizes=$( "$grep_cmd" -c '^' "${du_fn}.new" ) \
#     || { err_msg -d 2 "no sizes found by du: '$PWD/${du_fn}.new'"; exit; }

# # chown and move log file
# "$chown_cmd" "$lognm":"$lognm_group" "${du_fn}.new"
# /bin/mv -f "${du_fn}.new" "$du_fn"

# if [[ -s "${du_fails}.new" ]]
# then
#     /bin/mv -f "${du_fails}.new" "$du_fails"
# else
#     /bin/rm -f "${du_fails}.new" "$du_fails"  # rm if empty
# fi

# err_msg -d i "Files and sizes output to $PWD/$du_fn"
# err_msg -d i "Found $n_files filenames, reported sizes on $n_sizes"

# # output files sorted by size
# # -h handles human-readable chars for K, M, G, etc
# # sed prepends spaces to each line; head sends sigpipe to sort (causes pipefail)
# err_msg -d i "Largest 12:"
# command sort -rh "$du_fn" \
#     | command head -n 12 \
#     | "$sed_cmd" 's/^/    /' \
#     || ignore_sigpipe $?
