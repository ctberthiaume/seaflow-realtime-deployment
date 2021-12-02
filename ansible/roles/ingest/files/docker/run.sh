#!/bin/bash
# Takes two args: minio bucket, key
#
# env vars:
# - GRAFANA_DASHBOARDS_DIR = where to place dashboard JSON files
# - GRAFANA_DATASOURCES_DIR = where to place grafana datasource yaml definitions
# - GF_SECURITY_ADMIN_PASSWORD = password for grafana user "admin"
# - GRAFANA_ADDRESS = grafana HTTP endpoint address, e.g. 127.0.0.1:3000
# - PGHOST = postgres host, without port, e.g. 127.0.0.1 or hostname
# - PGPORT = postgres port
# - PGUSER = postgres user
# - PGPASSWORD = postgres password for PGUSER
# - ROUSER = read-only postgres user
# - ROPASSWORD = password for ROUSER
# - MC_HOST_minio = minio http api endpoint with embedded credentials
#                   e.g. "http://USER:SECRET@@127.0.0.1:9000"

if [[ $# -eq 2 && -n $1 && -n $2 ]]
then
    # Must URL decode key
    objectkey=$(echo -n "$2" | python3 -c "import sys; from urllib.parse import unquote; print(unquote(sys.stdin.read()));")
    objectfilename=$(basename "$objectkey")
    if [[ "$1" = "debug" ]]
    then
        echo "debug: bucket=$1 key=$objectkey"
        exit
    elif [[ "$1" = "dashboard" ]]; then  # the bucket
        # Record which file we're processing and make sure it's there
        if mc ls "minio/$1/$objectkey"; then
            DASHJSON="${GRAFANA_DASHBOARDS_DIR}/$objectfilename"
            echo "Updating dashboard JSON file minio/$1/$objectkey as ${DASHJSON}" >&2
            mc cat "minio/$1/$objectkey" >"${DASHJSON}" || exit 1
            # Should automatically reload dashboards, no need to manually trigger
            # a reload
        fi
    elif [[ "$1" = "data" || "$1" = "user-data" ]] ; then  # the bucket
        # Record which file we're processing and make sure it's there
        if mc ls "minio/$1/$objectkey"; then
            mc cat "minio/$1/$objectkey" > /tmp/datafile
            sed -i 's/[[:blank:]\r]*$//' /tmp/datafile # remove trailing whitespace and carriage returns from every line
            tsdataformat clean -i /tmp/datafile -o - > /tmp/datafile_clean
            # Get pgdatabase and table name
            pgtable=$(awk 'NR == 1 {print $1; exit}' /tmp/datafile_clean)
            pgdatabase=$(awk 'NR == 2 {print $1; exit}' /tmp/datafile_clean)
            echo "Adding new data file minio/$1/$objectkey as db=$pgdatabase table=$pgtable" >&2
            # Add schema to DB
            python3 /app/tsdata2sql.py -v /tmp/datafile_clean || exit 1
            # Import to DB
            tsdata csv /tmp/datafile_clean - | \
                timescaledb-parallel-copy --truncate --workers 2 --batch-size 50000 --verbose \
                    --connection "host=$PGHOST user=$PGUSER sslmode=disable" \
                    --db-name "$pgdatabase" --table "${pgtable}_raw" --copy-options "CSV HEADER NULL 'NA'" || exit 1
            # Create and load datasource config if the yaml file doesn't exist
            dsyaml="${GRAFANA_DATASOURCES_DIR}/${pgdatabase}.yaml"
            if [[ ! -e "${dsyaml}" ]]; then
                echo "Creating datasource config file ${dsyaml}" >&2
                python3 /app/register_datasource.py "$pgdatabase" "${dsyaml}" || exit 1
                curl --silent --show-error -X 'POST' --user admin:"$GF_SECURITY_ADMIN_PASSWORD" "http://${GRAFANA_ADDRESS}/api/admin/provisioning/datasources/reload" || exit 1
            fi
        fi
    else
        echo "Error: unrecognized bucket name '$1'" >&2
        exit 1
    fi
else
    echo "No arguments"
fi
