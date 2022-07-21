#!/usr/bin/env bash

# find backed-up files from the latest backup archive process from borg
# and sort by size
#
# - reads and writes to ~/.config/borg, in the logged in user's home
# - requires recent borgmatic backup run with --files, or recent borg
#   backup run with --info --list --filter=AME...

# v0.1 (Jun 2022) by Andrew Davis (addavis@gmail.com)

# Configure some common variables, shell options, and functions
BS0="${BASH_SOURCE[0]}"
exc_fn=$(basename -- "$BS0")
exc_dir=$(dirname -- "$BS0")

src_dir=$(python -c "import os; print(os.path.dirname(os.path.realpath('$BS0')))")
source "$src_dir/bgo_functions.sh"

# requires root to reliably stat all files
[[ $(id -u) -eq 0 ]] || raise 2 "root or sudo required."

# find config dir based on logged-in user name (when running with sudo)
def_luser  # luser, luser_group, luser_home from bgo_functions

[[ -z ${BORG_CONFIG_DIR-} ]] && BORG_CONFIG_DIR="$luser_home/.config/borg"

cd "$BORG_CONFIG_DIR" \
    || raise 2 "could not cd to config dir: '$BORG_CONFIG_DIR'"

borg_logfile=borg_log.txt
chf_fn=borg_log_chfiles.txt
errf_fn=borg_errfiles.txt
du_fn=borg_log_chfile_sizes.txt
du_fails=${du_fn/sizes/fails}

[[ -r $borg_logfile ]] \
    || raise 2 "could not read logfile: '$borg_logfile'"

# check for any error files
sed -En 's/^.*INFO E (.*)/\1/ p' "$borg_logfile" >"$errf_fn.new"

if ! grep -qc '^' "$errf_fn.new"; then
    # no errors, as expected
    /bin/rm "$errf_fn.new"
else
    /bin/mv "$errf_fn.new" "$errf_fn"
    print_msg WARNING "Error files found, see $errf_fn:"
    head "$errf_fn"
fi

# parse log file to extract only file paths of changed files
sed -En 's/^.*INFO [AMC] (.*)/\1/ p' "$borg_logfile" >"$chf_fn.new"

n_files=$(grep -c '^' "$chf_fn.new")  \
    || { /bin/rm "$chf_fn.new"
         raise w "no filenames found in log"; }

/bin/mv "$chf_fn.new" "$chf_fn"


# compute file sizes for changed files
# - du's "cannot access" messages/errors occur for moved/deleted files
# - implementation notes:
#     + this works as long as there are no newlines in filenames (BSD du does not have
#       --files0-from)
#     + would like to do `du -hsc $(< $chf_fn)` but produces argument list too long for
#       a large number of files
#     + also, du doesn't read from stdin under BSD, so getting the total (-c) is tricky
#     + could also have used xargs -0:
#       <"$chf_fn" tr '\n' '\0' | xargs -0 -I '{}' sh -c \
#                                 "du -hs -- '{}' || true" >"$du_fn.new" 2>"$du_fails.new"
>"$du_fn.new"
>"$du_fails.new"
while IFS='' read -r fn; do
    du -hs -- "$fn" >>"$du_fn.new" 2>>"$du_fails.new" || true
done <"$chf_fn"

# ensure du output was as expected
n_sizes=$(grep -c '^' "$du_fn.new")  \
    || raise 2 "no sizes found by du: '$PWD/$du_fn.new'"

/bin/mv "$du_fn.new" "$du_fn"
/bin/mv "$du_fails.new" "$du_fails"
print_msg "Files and sizes output to $PWD/$du_fn"
print_msg "Found $n_files filenames, reported sizes on $n_sizes"

# output files sorted by size
# -h handles human-readable chars for K, M, G, etc
# sed prepends spaces to each line
print_msg "Largest 12:"
sort -rh "$du_fn" | head -n 12 | sed 's/^/    /'

# clean up
# [[ $1 == --noclean ]] || /bin/rm $chf_fn $du_fn

# chown instead
chown "$luser":"$luser_group" "$chf_fn" "$du_fn"
# chmod 0640 "$chf_fn" "$du_fn"
