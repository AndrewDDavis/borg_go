#!/usr/bin/env bash

# find backed-up files from the latest backup archive process from borg
# and sort by size
#
# - reads and writes to ~/.config/borg, in the logged in user's home
# - requires recent borgmatic backup run with --files, or recent borg
#   backup run with --info --list --filter=AME...

# v0.1 (Jun 2022) by Andrew Davis (addavis@gmail.com)

# log-style messages
script_bn=$(basename -- "$0")
function print_msg {
    # usage e.g.: print_msg ERROR "the script had a problem"
    local msg_type

    [[ $1 == DEBUG || $1 == INFO || $1 == WARNING || $1 == ERROR ]] \
        && { msg_type=$1; shift; } \
        || { msg_type=INFO; }

    printf "%s %s %s\n" "$(date)" "$script_bn [$msg_type]" "$*" >&2
}

# requires root to reliably stat all files
[[ $(id -u) -eq 0 ]] || { print_msg ERROR "root or sudo required."; exit 2; }

# Umask -- no write for group, nothing for other
umask 027

# find config dir based on logged-in user name (when running with sudo)
luser="$(logname)"
luser_home="$(eval echo -n ~$luser)"  # works b/c variable replacement done before running

if [[ -z $BORG_CONFIG_DIR ]]; then
    BORG_CONFIG_DIR="${luser_home}/.config/borg"
fi

borg_logfile=borg_log.txt
chf_fn=borg_chfiles.txt
fs_fn=borg_chfile_sizes.txt

cd "$BORG_CONFIG_DIR" \
    || { print_msg ERROR "could not cd to config dir: '$BORG_CONFIG_DIR'"; exit 2; }

[[ -r $borg_logfile ]] \
    || { print_msg ERROR "could not read logfile: '$borg_logfile'"; exit 2; }

# parse log file to extract only file paths
sed -En 's/^.*INFO [AMCE-] (.*)/\1/ p' $borg_logfile >"${chf_fn}.new"

# need to parse wc output with sed because BSD and Gnu give different output
# - could also have just piped to xargs I think
n_files=$(wc -l "${chf_fn}.new" | sed -En 's/^[ \t]*([0-9]+) .*/\1/ p')

if [[ $n_files =~ [^0-9] ]]; then

    print_msg ERROR "expected non-negative integer for n_files: $n_files"
    exit 2

elif [[ $n_files -eq 0 ]]; then

    print_msg WARNING "no filenames found in log"
    /bin/rm "${chf_fn}.new"
    exit 0

else

    /bin/mv "${chf_fn}.new" "${chf_fn}"
fi

# find file sizes for changed files
# - du's "cannot access" messages occur for moved/deleted files
# - this works as long as there are no newlines in filenames (no --files0-from in BSD du)
# - for a large number of files, you may get argument list too long with
#   du -hsc $(< $chf_fn)
# - also, du doesn't read from stdin under BSD, so getting the total (-c) is tricky,
#   might require awk

printf '%s\0' $(< "$chf_fn") | xargs -0 du -hs -- 2>/dev/null >"${fs_fn}.new"

n_sizes=$(wc -l "${fs_fn}.new" | sed -En 's/^[ \t]*([0-9]+) .*/\1/ p')

# ensure du output was as expected
if [[ $n_sizes =~ [^0-9] ]]; then

    print_msg ERROR "expected non-negative integer for n_sizes: $n_sizes"
    exit 2

elif [[ $n_sizes -eq 0 ]]; then

    print_msg ERROR "no sizes found by du: '${PWD}/${fs_fn}.new'"
    exit 2
fi

/bin/mv "${fs_fn}.new" "$fs_fn"
print_msg "Files and sizes output to ${PWD}/${fs_fn}."
print_msg "Found $n_files filenames, reported sizes on $n_sizes"

# output files sorted by size
# -h handles human-readable chars for K, M, G, etc
# sed prepends spaces to each line
print_msg "Largest 12:"
sort -rh "$fs_fn" | head -n 12 | sed 's/^/    /'

# clean up
# [[ $1 == --noclean ]] || /bin/rm $chf_fn $fs_fn

# chown instead
chown $luser "$chf_fn" "$fs_fn"
# chmod 0640 "$chf_fn" "$fs_fn"