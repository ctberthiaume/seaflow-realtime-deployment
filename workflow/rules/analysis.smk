rule concat_sfl:
    input:
        evt_dir=f"{config['evt_root_dir']}/{{cruise}}_evt",
    output:
        sfl=f"<results>/{{cruise}}_{config['instrument']}.sfl",
    params:
        instrument=config["instrument"],
        seaflowpy_path=config["seaflowpy_path"],
    log: "<logs>/concat_sfl_{cruise}.log"
    shell:
        """
        # Function to rotate logs on exit (runs on success or failure)
        rotate_logs() {{
            rm -f "{log}.12"
            for i in {{11..1}}; do
                [[ -e "{log}.$i" ]] && mv "{log}.$i" "{log}.$((i+1))"
            done
            # Copy current log to .1 to save it before next run deletes it
            [[ -e "{log}" ]] && cp "{log}" "{log}.1"
        }}
        trap rotate_logs EXIT

        echo "$(date -u): Concatenating SFL files for cruise {wildcards.cruise} and instrument {params.instrument}" > {log:q}
        echo "$(date -u): Using EVT directory: {input.evt_dir:q}" >> {log:q}
        {params.seaflowpy_path:q} sfl print $(/usr/bin/find -L {input.evt_dir:q} -name '*.sfl' | sort) > {output.sfl:q} 2>> {log:q}
        echo "$(date -u): Finished concatenating SFL files for cruise {wildcards.cruise}" >> {log:q}
        """

rule seaflow_analysis:
    input:
        repo_db=config["repo_dir"] + f"/dbs/{{cruise}}_{config['instrument']}.db",
        sfl=rules.concat_sfl.output.sfl,
        evt_dir=f"{config['evt_root_dir']}/{{cruise}}_evt",
    output:
        status=f"<results>/seaflow_analysis/{{cruise}}/done.txt",
    log: "<logs>/seaflow_analysis.{cruise}.log"
    threads: config["seaflow_analysis_threads"]
    params:
        db=lambda wildcards, input, output: str(Path(output.status).parent / f"{wildcards.cruise}.db"),
        opp_dir=lambda wildcards, input, output: str(Path(output.status).parent / f"{wildcards.cruise}_opp"),
        vct_dir=lambda wildcards, input, output: str(Path(output.status).parent / f"{wildcards.cruise}_vct"),
        stats_abund_file=lambda wildcards, input, output: str(Path(output.status).parent / f"stats-abund.{wildcards.cruise}.tsdata"),
        sfl_file=lambda wildcards, input, output: str(Path(output.status).parent / f"sfl.popcycle.{wildcards.cruise}.tsdata"),
        sync_stats_abund_file=f"{config['sync_dir']}/seaflow-analysis/{{cruise}}/stats-abund.{{cruise}}.tsdata",
        sync_sfl_file=f"{config['sync_dir']}/seaflow-analysis/{{cruise}}/sfl.popcycle.{{cruise}}.tsdata",
        instrument=config["instrument"],
        temp_db=lambda wildcards, input, output: str(Path(output.status).parent / f"{wildcards.cruise}.db") + ".tmp",
        correction=config["correction"],
        volume=config["volume_constant"],
        maxeventrate=config["max_event_rate"],
        sync_dir=f"{config['sync_dir']}/seaflow-analysis/{{cruise}}",
        timeout_path=config["timeout_path"],
        realtime_script=Path(workflow.current_basedir) / "../scripts/realtime-popcycle.R",
    shell:
        """
        # Function to rotate logs on exit (runs on success or failure)
        rotate_logs() {{
            rm -f "{log}.12"
            for i in {{11..1}}; do
                [[ -e "{log}.$i" ]] && mv "{log}.$i" "{log}.$((i+1))"
            done
            # Copy current log to .1 to save it before next run deletes it
            [[ -e "{log}" ]] && cp "{log}" "{log}.1"
        }}
        trap rotate_logs EXIT

        echo "$(date -u): Starting seaflow analysis for cruise {wildcards.cruise} and instrument {params.instrument}" > {log:q}
        echo "$(date -u): seaflowpy version $(seaflowpy version)" >> {log:q} 2>&1
        # DB preparation section
        # -----------------------------------------------------------------------------
        if [[ ! -e {params.db:q} ]]; then
            echo "$(date -u): Creating new temp database {params.temp_db} for cruise {wildcards.cruise} and instrument {params.instrument}" >> {log:q}
            seaflowpy db create {wildcards.cruise} {params.instrument} {params.temp_db:q} >> {log:q} 2>&1
        else
            echo "$(date -u): Database {params.db:q} already exists. Copying to temp file {params.temp_db:q}." >> {log:q}
            cp {params.db:q} {params.temp_db:q}
        fi

        # Populate with latest repository data
        echo "$(date -u): Populating database {params.temp_db} with repository data from {input.repo_db}" >> {log:q}
        sqlite3 {params.temp_db:q} 'DROP TABLE IF EXISTS filter' >> {log:q} 2>&1
        sqlite3 {input.repo_db:q} ".dump filter" | sqlite3 {params.temp_db:q} >> {log:q} 2>&1
        sqlite3 {params.temp_db:q} 'DROP TABLE IF EXISTS gating' >> {log:q} 2>&1
        sqlite3 {input.repo_db:q} ".dump gating" | sqlite3 {params.temp_db:q} >> {log:q} 2>&1
        sqlite3 {params.temp_db:q} 'DROP TABLE IF EXISTS poly' >> {log:q} 2>&1
        sqlite3 {input.repo_db:q} ".dump poly" | sqlite3 {params.temp_db:q} >> {log:q} 2>&1
        sqlite3 {params.temp_db:q} 'DROP TABLE IF EXISTS gating_plan' >> {log:q} 2>&1
        sqlite3 {input.repo_db:q} ".dump gating_plan" | sqlite3 {params.temp_db:q} >> {log:q} 2>&1
        sqlite3 {params.temp_db:q} 'DROP TABLE IF EXISTS filter_plan' >> {log:q} 2>&1
        sqlite3 {input.repo_db:q} ".dump filter_plan" | sqlite3 {params.temp_db:q} >> {log:q} 2>&1

        echo "$(date -u): Populating database {params.temp_db} with SFL data from {input.sfl}" >> {log:q}
        seaflowpy db import-sfl -f {input.sfl:q} {params.temp_db:q} >> {log:q} 2>&1

        echo "$(date -u): Database preparation complete for cruise {wildcards.cruise} and instrument {params.instrument}" >> {log:q}

        # Filtering and classification section
        # -----------------------------------------------------------------------------
        echo "$(date -u): popcycle R package version:" >> {log:q}
        Rscript --slave -e 'message(packageVersion("popcycle"))' >> {log:q} 2>&1

        # Classify and produce summary image files
        echo "$(date -u): Starting filtering and classification for cruise {wildcards.cruise}" >> {log:q}
        echo "$(date -u): Using evt directory {input.evt_dir} and input db {params.temp_db}" >> {log:q}
        echo "$(date -u): Filtering and classifying data in {params.db}, {params.opp_dir}, and {params.vct_dir}" >> {log:q}
        {params.timeout_path} -k 60s 2h \
            Rscript --slave {params.realtime_script:q} \
                --instrument "{params.instrument}" \
                --db {params.temp_db:q} \
                --evt-dir {input.evt_dir:q} \
                --opp-dir {params.opp_dir:q} \
                --vct-dir {params.vct_dir:q} \
                --stats-abund-file {params.stats_abund_file:q} \
                --sfl-file {params.sfl_file:q} \
                --volume "{params.volume}" \
                --correction "{params.correction}" \
                --max-event-rate "{params.maxeventrate}" \
                --cores {threads} >> {log:q} 2>&1
        # TODO: check for timeout specifically
        echo "$(date -u): classification completed successfully" >> {log:q}
        echo "$(date -u): Moving temp database {params.temp_db} to final location {params.db}" >> {log:q}
        mv {params.temp_db:q} {params.db:q} 2>> {log:q}

        # Export section
        # -----------------------------------------------------------------------------
        # # Copy for sync to shore
        echo "$(date -u): Copying data for sync" >> {log:q}
        [[ ! -d {params.sync_dir:q} ]] && mkdir -p {params.sync_dir:q}
        cp -a {params.stats_abund_file:q} {params.sync_dir:q} 2>> {log:q}
        cp -a {params.sfl_file:q} {params.sync_dir:q} 2>> {log:q}
        echo "$(date -u): Completed sync copy" >> {log:q}

        # Mark analysis as done
        date -u > {output.status:q}

        echo "$(date -u): Finished seaflow analysis for cruise {wildcards.cruise}" >> {log:q}
        echo "" >> {log:q}
        """

rule subsample:
    input:
        evt_dir=rules.seaflow_analysis.input.evt_dir,
        opp_dir="<results>/seaflow_analysis/{cruise}/{cruise}_opp",
        analysis_status=rules.seaflow_analysis.output.status,  # make sure OPP is ready
    output:
        status="<results>/subsample/{cruise}/done.txt",
    params:
        seaflowpy_path=config["seaflowpy_path"],
        out_dir=lambda wildcards, input, output: Path(output.status).parent,
        sync_dir=f"{config['sync_dir']}/subsample/{{cruise}}",
        instrument=config["instrument"],
        start=config["start"],
        sample_tail_hours=config["tail_hours"],
        sample_full_count=config["sample_noise_count"],
        bead_sample_min_fsc=config["bead_sample_min_fsc"],
        bead_sample_min_pe=config["bead_sample_min_pe"],
        bead_sample_min_chl=config["bead_sample_min_chl"],
        opp_sample_count=config["opp_sample_count"],
    log: "<logs>/subsample.{cruise}.log"
    shell:
        """
        set +e           # disable exit on error to handle timeouts
        set +o pipefail  # disable pipefail since we have pipes in this script

        # Function to rotate logs on exit (runs on success or failure)
        rotate_logs() {{
            rm -f "{log}.12"
            for i in {{11..1}}; do
                [[ -e "{log}.$i" ]] && mv "{log}.$i" "{log}.$((i+1))"
            done
            # Copy current log to .1 to save it before next run deletes it
            [[ -e "{log}" ]] && cp "{log}" "{log}.1"
        }}
        trap rotate_logs EXIT

        echo "$(date -u): Starting subsampling for cruise {wildcards.cruise} and instrument {params.instrument}" > {log:q}
        echo "$(date -u): Using EVT directory: {input.evt_dir:q}" >> {log:q}
        echo "$(date -u): seaflowpy version $({params.seaflowpy_path:q} version)" >> {log:q} 2>&1
        
        # Create root output directory if it doesn't exist
        [[ -d {params.out_dir:q} ]] || mkdir -p {params.out_dir:q}

        # First get date range for last hour of EVT data
        echo "$(date -u): EVT date range" >> {log:q}
        timeout -k 60s 5m {params.seaflowpy_path:q} evt dates \
            --min-date "{params.start}" \
            --tail-hours "{params.sample_tail_hours}" \
            {input.evt_dir:q} | tee {params.out_dir:q}/evt_dates.txt >> {log:q} 2>&1
        status=$?
        if [[ $status -eq 124 ]]; then
            echo "$(date -u): evt dates killed by timeout sigint" >> {log:q}
            exit $status
        elif [[ $status -eq 137 ]]; then
            echo "$(date -u): evt dates killed by timeout sigkill" >> {log:q}
            exit $status
        elif [[ $status -gt 0 ]]; then
            echo "$(date -u): evt dates exited with an error, status = $status" >> {log:q}
            exit $status
        else
            echo "$(date -u): evt dates completed successfully" >> {log:q}
        fi

        if [[ ! -s {params.out_dir:q}/evt_dates.txt ]]; then
            echo "$(date -u): No EVT data within date range" >> {log:q}
            exit
        fi

        # Get output directory name and retrieve date range
        mindate=$(awk '{{print $1}}' {params.out_dir:q}/evt_dates.txt)
        maxdate=$(awk '{{print $2}}' {params.out_dir:q}/evt_dates.txt)
        outdir="{params.out_dir}/$mindate"

        if [[ -d "$outdir" ]]; then
            # Python one-liner: returns exit code 0 (success) if older than 3600s, 1 (fail) otherwise
            if python3 -c "import os, time, sys; sys.exit(0 if (time.time() - os.path.getmtime(sys.argv[1])) > 3600 else 1)" "$outdir"; then
                echo "$(date -u): Directory $outdir exists and was created more than 1 hour ago." >> {log:q}
            else
                echo "$(date -u): Directory $outdir exists and was created less than 1 hour ago." >> {log:q}
                echo "$(date -u): Skipping subsampling." >> {log:q}
                # Touch status to indicate the rule ran, but don't update timestamp.
                # Timestamp in status file indicates last subsampling run.
                touch {output.status:q}
                exit 0
            fi
        fi

        # Create output directory if it doesn't exist
        [[ -d "$outdir" ]] || mkdir -p "$outdir"
        echo "$(date -u): Output directory: $outdir" >> {log:q}

        # Full sample for noise estimation
        if [[ ! -e "$outdir/last-{params.sample_tail_hours}-hours.fullSample.parquet" ]]; then
            echo "$(date -u): Subsampling with no filters" >> {log:q}
            echo "$(date -u): mindate = $mindate, maxdate = $maxdate" >> {log:q}
            echo "$(date -u): output path = $outdir/last-{params.sample_tail_hours}-hours.fullSample.parquet" >> {log:q}
            timeout -k 60s 5m {params.seaflowpy_path:q} evt sample \
                --min-date "$mindate" \
                --max-date "$maxdate" \
                --count "{params.sample_full_count}" \
                --file-fraction 1.0 \
                --verbose \
                --outpath "$outdir/last-{params.sample_tail_hours}-hours.fullSample.parquet" \
                {input.evt_dir:q} >> {log:q} 2>&1
            status=$?
            if [[ $status -eq 124 ]]; then
                echo "$(date -u): full subsample killed by timeout sigint" >> {log:q}
                exit $status
            elif [[ $status -eq 137 ]]; then
                echo "$(date -u): full subsample killed by timeout sigkill" >> {log:q}
                exit $status
            elif [[ $status -gt 0 ]]; then
                echo "$(date -u): full subsample exited with an error, status = $status" >> {log:q}
                exit $status
            else
                echo "$(date -u): full subsample completed successfully" >> {log:q}
            fi
        fi

        # Bead sample
        if [[ ! -e "$outdir/last-{params.sample_tail_hours}-hours.beadSample.parquet" ]]; then
            echo "$(date -u): Subsampling for beads" >> {log:q}
            echo "$(date -u): mindate = $mindate, maxdate = $maxdate" >> {log:q}
            echo "$(date -u): output path = $outdir/last-{params.sample_tail_hours}-hours.beadSample.parquet" >> {log:q}
            timeout -k 60s 5m {params.seaflowpy_path:q} evt sample \
                --min-date "$mindate" \
                --max-date "$maxdate" \
                --count 1500 \
                --noise-filter \
                --saturation-filter \
                --min-fsc "{params.bead_sample_min_fsc}" \
                --min-pe "{params.bead_sample_min_pe}" \
                --min-chl "{params.bead_sample_min_chl}"  \
                --multi --file-fraction 1.0 \
                --verbose \
                --outpath "$outdir/last-{params.sample_tail_hours}-hours.beadSample.parquet" \
                {input.evt_dir:q} >> {log:q} 2>&1
            status=$?
            if [[ $status -eq 124 ]]; then
                echo "$(date -u): bead subsample killed by timeout sigint" >> {log:q}
                exit $status
            elif [[ $status -eq 137 ]]; then
                echo "$(date -u): bead subsample killed by timeout sigkill" >> {log:q}
                exit $status
            elif [[ $status -gt 0 ]]; then
                echo "$(date -u): bead subsample exited with an error, status = $status" >> {log:q}
                exit $status
            else
                echo "$(date -u): bead subsample completed successfully" >> {log:q}
            fi
        fi
        

        # OPP sample
        if [[ ! -e "$outdir/$mindate.1H.opp.sample.parquet" ]]; then
            echo "$(date -u): Subsampling OPP" >> {log:q}
            echo "$(date -u): mindate = $mindate, maxdate = $maxdate" >> {log:q}
            echo "$(date -u): output path = $outdir/$mindate.1H.opp.sample.parquet" >> {log:q}
            timeout -k 60s 5m {params.seaflowpy_path:q} opp sample \
                --min-date "$mindate" \
                --max-date "$maxdate" \
                --count "{params.opp_sample_count}" \
                --outpath "$outdir/$mindate.1H.opp.sample.parquet" \
                {input.opp_dir:q} >> {log:q} 2>&1
                status=$?
                if [[ $status -eq 124 ]]; then
                    echo "$(date -u): OPP subsample killed by timeout sigint" >> {log:q}
                    exit $status
                elif [[ $status -eq 137 ]]; then
                    echo "$(date -u): OPP subsample killed by timeout sigkill" >> {log:q}
                    exit $status
                elif [[ $status -gt 0 ]]; then
                    echo "$(date -u): OPP subsample exited with an error, status = $status" >> {log:q}
                    exit $status
                else
                    echo "$(date -u): OPP subsample completed successfully" >> {log:q}
                fi
        fi

        # Copy for sync
        [[ -d {params.sync_dir:q} ]] || mkdir -p {params.sync_dir:q} 2>> {log:q}
        echo "$(date -u): Copying EVT date range to sync folder" >> {log:q}
        cp -a "{params.out_dir:q}/evt_dates.txt" {params.sync_dir:q} 2>> {log:q}
        echo "$(date -u): Copying latest subsample folder '$outdir' to sync dir '{params.sync_dir}'" >> {log:q}
        cp -ra "$outdir" {params.sync_dir:q}

        echo "$(date -u): Finished subsampling for cruise {wildcards.cruise}" >> {log:q}
        # Timestamp in status file indicates last subsampling run.
        date -u > {output.status:q}
        """

rule seaflowpy_version:
    output:
        version_file="<results>/seaflowpy_version.txt",
    params:
        seaflowpy_path=config["seaflowpy_path"],
    log: "<logs>/seaflowpy_version.log"
    shell:
        """
        echo "$(date -u): Retrieving seaflowpy version" > {log:q}
        {params.seaflowpy_path:q} version > {output.version_file:q} 2>> {log:q}
        echo "$(date -u): seaflowpy version written to {output.version_file}" >> {log:q}
        """

rule popcycle_version:
    output:
        version_file="<results>/popcycle_version.txt",
    log: "<logs>/popcycle_version.log"
    shell:
        """
        echo "$(date -u): Retrieving popcycle R package version" > {log:q}
        Rscript --slave -e 'packageVersion("popcycle")' > {output.version_file:q} 2>> {log:q}
        echo "$(date -u): popcycle version written to {output.version_file}" >> {log:q}
        """
