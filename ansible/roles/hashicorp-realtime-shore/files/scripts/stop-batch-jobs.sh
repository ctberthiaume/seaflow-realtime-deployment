#!/usr/bin/env bash
# Stop all future and running periodic jobs
# usage: stop-batch-jobs.sh [-purge] [parent-job-name]...

# The skeleton for the option parsing section of this script was pulled from
# https://mywiki.wooledge.org/BashFAQ/035.
die() {
    printf '%s\n' "$1" >&2
    exit 1
}

# Initialize all the option variables.
# This ensures we are not contaminated by variables from the environment.
purge=0

while :; do
    case $1 in
        -h|-\?|--help)
            printf "stop-batch-jobs.sh\n"
            printf "\n"
            printf "Stop a batch job and all jobs with the same name as a prefix"
            printf "\n"
            printf "Options:\n"
            printf -- "--purge: run 'nomad job stop -purge\n"
            printf "\n"
            exit
            ;;
        --purge)
            purge=1
            ;;
        --)              # End of all options.
            shift
            break
            ;;
        -?*)
            printf 'WARN: Unknown option (ignored): %s\n' "$1" >&2
            ;;
        *)               # Default case: No more options, so break out of the loop.
            break
    esac
    shift
done

if [[ $# -eq 0 ]]; then
  echo "no job name provided"
  exit
fi
jobname=$1

if [[ $purge -eq 1 ]]; then
  echo "stopping and purging all jobs with prefix = $1"
else
  echo "stopping all jobs with prefix = $1"
fi

echo "jobs to stop are ..."
nomad job status | awk -v patt="^$jobname" '$1 ~ patt {print $1}'
echo ""
if [[ $purge -eq 1 ]]; then
  nomad job status | awk -v patt="^$jobname" '$1 ~ patt {print $1}' | xargs -I {} nomad job stop -yes -detach -purge {}
else
  nomad job status | awk -v patt="^$jobname" '$1 ~ patt {print $1}' | xargs -I {} nomad job stop -yes -detach {}
fi
