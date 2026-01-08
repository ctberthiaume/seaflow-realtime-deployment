rule concat_sfl:
    input:
        evt_status=f"{config['evt_root_dir']}/{{cruise}}/SFlog.txt"  # use log file as marker for EVT updates
    output:
        sfl=f"<results>/{{cruise}}_{config['instrument']}.sfl",
    params:
        instrument=config["instrument"],
        seaflowpy_path=config["seaflowpy_path"],
        evt_dir=f"{config['evt_root_dir']}/{{cruise}}/evt",
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
        echo "$(date -u): Using EVT directory: {params.evt_dir:q}" >> {log:q}
        {params.seaflowpy_path:q} sfl print $(/usr/bin/find -L {params.evt_dir:q} -name '*.sfl' | sort) > {output.sfl:q} 2>> {log:q}
        echo "$(date -u): Finished concatenating SFL files for cruise {wildcards.cruise}" >> {log:q}
        """

rule seaflow_analysis:
    input:
        repo_db=config["repo_dir"] + f"/dbs/{{cruise}}_{config['instrument']}.db",
        sfl=rules.concat_sfl.output.sfl,
    output:
        status=f"<results>/seaflow_analysis/{{cruise}}/done.txt",
    log: "<logs>/seaflow_analysis.{cruise}.log"
    threads: config["seaflow_analysis_threads"]
    params:
        db=lambda wildcards, input, output: str(Path(output.status).parent / f"{wildcards.cruise}.db"),
        evt_dir=rules.concat_sfl.params.evt_dir,
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
        seaflowpy_path=config["seaflowpy_path"],
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
        echo "$(date -u): seaflowpy version $({params.seaflowpy_path} version)" >> {log:q} 2>&1
        # DB preparation section
        # -----------------------------------------------------------------------------
        if [[ ! -e {params.db:q} ]]; then
            echo "$(date -u): Creating new temp database {params.temp_db} for cruise {wildcards.cruise} and instrument {params.instrument}" >> {log:q}
            {params.seaflowpy_path:q} db create {wildcards.cruise} {params.instrument} {params.temp_db:q} >> {log:q} 2>&1
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
        {params.seaflowpy_path:q} db import-sfl -f {input.sfl:q} {params.temp_db:q} >> {log:q} 2>&1

        echo "$(date -u): Database preparation complete for cruise {wildcards.cruise} and instrument {params.instrument}" >> {log:q}

        # Filtering and classification section
        # -----------------------------------------------------------------------------
        echo "$(date -u): popcycle R package version:" >> {log:q}
        Rscript --slave -e 'message(packageVersion("popcycle"))' >> {log:q} 2>&1

        # Classify and produce summary image files
        echo "$(date -u): Starting filtering and classification for cruise {wildcards.cruise}" >> {log:q}
        echo "$(date -u): Using evt directory {params.evt_dir} and input db {params.temp_db}" >> {log:q}
        echo "$(date -u): Filtering and classifying data in {params.db}, {params.opp_dir}, and {params.vct_dir}" >> {log:q}
        {params.timeout_path} -k 60s 2h \
            Rscript --slave {params.realtime_script:q} \
                --instrument "{params.instrument}" \
                --db {params.temp_db:q} \
                --evt-dir {params.evt_dir:q} \
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
        analysis_status=rules.seaflow_analysis.output.status,  # make sure OPP is ready
    output:
        status=f"<results>/subsample/{{cruise}}/{config['instrument']}/done.txt",
    params:
        seaflowpy_path=config["seaflowpy_path"],
        req_script=Path(workflow.current_basedir) / "../scripts/subsampling_required.py",
        evt_dir=rules.concat_sfl.params.evt_dir,
        opp_dir=f"results/seaflow_analysis/{{cruise}}/{{cruise}}_opp",  # don't use rules.seaflow_analysis.params.opp_dir, it will evaluate to an OPP dir in subsample dir
        out_dir=lambda wildcards, input, output: Path(output.status).parent,
        sync_dir=f"{config['sync_dir']}/subsample/{{cruise}}/{config['instrument']}/",
        instrument=config["instrument"],
        start=config["start"],
        sample_tail_hours=config["tail_hours"],
        sample_full_count=config["sample_noise_count"],
        bead_sample_min_fsc=config["bead_sample_min_fsc"],
        bead_sample_min_pe=config["bead_sample_min_pe"],
        bead_sample_min_chl=config["bead_sample_min_chl"],
        opp_sample_count=config["opp_sample_count"],
        timeout_path=config["timeout_path"],
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
        echo "$(date -u): Using EVT directory: {params.evt_dir:q}" >> {log:q}
        echo "$(date -u): seaflowpy version $({params.seaflowpy_path:q} version)" >> {log:q} 2>&1
        
        # Create root output directory if it doesn't exist
        [[ -d {params.out_dir:q} ]] || mkdir -p {params.out_dir:q}

        # First get date range for last hour of EVT data
        echo "$(date -u): EVT date range" >> {log:q}
        {params.timeout_path:q} -k 60s 5m {params.seaflowpy_path:q} evt dates \
            --min-date "{params.start}" \
            --tail-hours "{params.sample_tail_hours}" \
            {params.evt_dir:q} | tee {params.out_dir:q}/evt_dates.txt >> {log:q} 2>&1
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

        # Get output directory name and check if subsampling is required
        mindate=$(awk '{{print $1}}' {params.out_dir:q}/evt_dates.txt)
        maxdate=$(awk '{{print $2}}' {params.out_dir:q}/evt_dates.txt)
        outdir="{params.out_dir}/$mindate"
        echo "$(date -u): python3 {params.req_script:q} {params.out_dir:q} $mindate" >> {log:q}
        req_output=$(python3 {params.req_script:q} "{params.out_dir:q}" "$mindate" 2>> {log:q})
        echo "$(date -u): Subsampling required output: $req_output" >> {log:q}

        if [[ $req_output = "True" ]]; then
            echo "$(date -u): Subsampling required for output directory $outdir" >> {log:q}
        else
            echo "$(date -u): Subsampling not required for output directory $outdir" >> {log:q}
            exit 0
        fi

        # Create output directory if it doesn't exist
        [[ -d "$outdir" ]] || mkdir -p "$outdir"
        echo "$(date -u): Output directory: $outdir" >> {log:q}

        # Full sample for noise estimation
        if [[ ! -e "$outdir/last-{params.sample_tail_hours}-hours.fullSample.parquet" ]]; then
            echo "$(date -u): Subsampling with no filters" >> {log:q}
            echo "$(date -u): mindate = $mindate, maxdate = $maxdate" >> {log:q}
            echo "$(date -u): output path = $outdir/last-{params.sample_tail_hours}-hours.fullSample.parquet" >> {log:q}
            {params.timeout_path:q} -k 60s 5m {params.seaflowpy_path:q} evt sample \
                --min-date "$mindate" \
                --max-date "$maxdate" \
                --count "{params.sample_full_count}" \
                --file-fraction 1.0 \
                --verbose \
                --outpath "$outdir/last-{params.sample_tail_hours}-hours.fullSample.parquet" \
                {params.evt_dir:q} >> {log:q} 2>&1
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
            {params.timeout_path:q} -k 60s 5m {params.seaflowpy_path:q} evt sample \
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
                {params.evt_dir:q} >> {log:q} 2>&1
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
            {params.timeout_path:q} -k 60s 5m {params.seaflowpy_path:q} opp sample \
                --min-date "$mindate" \
                --max-date "$maxdate" \
                --count "{params.opp_sample_count}" \
                --outpath "$outdir/$mindate.1H.opp.sample.parquet" \
                {params.opp_dir:q} >> {log:q} 2>&1
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
        cp -a "$outdir" {params.sync_dir:q} 2>> {log:q}

        echo "$(date -u): Finished subsampling for cruise {wildcards.cruise}" >> {log:q}
        touch {output.status:q}
        """

rule seaflog:
    input:
        log_file=f"{config['evt_root_dir']}/{{cruise}}/SFlog.txt",
    output:
        seaflog_file="<results>/seaflog/{cruise}/seaflog.{cruise}.tsdata",
    params:
        seaflog_path=config["seaflog_path"],
        instrument=config["instrument"],
        start=config["start"],
        end=config["end"],
        sync_dir=f"{config['sync_dir']}/seaflog/{{cruise}}",
    log: "<logs>/seaflog.{cruise}.log"
    shell:
        """
        {params.seaflog_path:q} --version >> {log:q} 2>&1
        echo "$(date -u): Generating seaflog for cruise {wildcards.cruise} and instrument {params.instrument}" >> {log:q}
        {params.seaflog_path:q} \
            --filetype SeaFlowInstrumentLog_{params.instrument} \
            --project {wildcards.cruise} \
            --description "SeaFlow instrument log for {wildcards.cruise}, {params.start} - {params.end}" \
            --earliest "{params.start}" \
            --latest "{params.end}" \
            --logfile {input.log_file:q} \
            --outfile {output.seaflog_file:q} \
            --quiet >> {log:q} >> {log:q} 2>&1
        echo "$(date -u): Finished generating seaflog for cruise {wildcards.cruise}" >> {log:q}

        # Copy for sync
        [[ -d {params.sync_dir:q} ]] || mkdir -p {params.sync_dir:q} 2>> {log:q}
        echo "$(date -u): Copying seaflog file to sync folder" >> {log:q}
        cp -a {output.seaflog_file:q} {params.sync_dir:q} 2>> {log:q}
        echo "$(date -u): Finished copying seaflog file to sync folder" >> {log:q}
        """

rule diagnostics:
    input:
        seaflow_analysis_done=rules.seaflow_analysis.output.status,
        subsample_done=rules.subsample.output.status,
    output:
        background_file="<results>/seaflow-diagnostics/{cruise}/background.{cruise}.tsdata",
        drift_file="<results>/seaflow-diagnostics/{cruise}/drift.{cruise}.tsdata",
    params:
        stats_abund_file=lambda wildcards, input, output: Path(input.seaflow_analysis_done).parent / f"stats-abund.{wildcards.cruise}.tsdata",
        subsample_dir=lambda wildcards, input, output: Path(input.subsample_done).parent,
        instrument=config["instrument"],
        timeout_path=config["timeout_path"],
        diag_script=Path(workflow.current_basedir) / "../scripts/realtime-diagnostics.R",
        sync_dir=f"{config['sync_dir']}/seaflow-diagnostics/{{cruise}}",
    log: "<logs>/seaflow-diagnostics.{cruise}.log"
    shell:
        """
        echo "$(date -u): Starting realtime diagnostics for cruise {wildcards.cruise}" >> {log:q}

        {params.timeout_path:q} -k 60s 2h \
        Rscript --slave {params.diag_script:q} \
            --instrument {params.instrument} \
            --cruise {wildcards.cruise} \
            --subsample-dir {params.subsample_dir:q} \
            --stats-file {params.stats_abund_file:q} \
            --background-file {output.background_file:q} \
            --drift-file {output.drift_file:q} >> {log:q} 2>&1
        status=$?
        if [[ $status -eq 124 ]]; then
            echo "$(date -u): diagnostics killed by timeout sigint" 1>&2
        elif [[ $status -eq 137 ]]; then
            echo "$(date -u): diagnostics killed by timeout sigkill" 1>&2
        elif [[ $status -gt 0 ]]; then
            echo "$(date -u): diagnostics exited with an error, status = $status" 1>&2
        else
            echo "$(date -u): diagnostics completed successfully" 1>&2
        fi

        # Copy for sync
        [[ -d {params.sync_dir:q} ]] || mkdir -p {params.sync_dir:q} 2>> {log:q}
        echo "$(date -u): Copying background and drift files to sync folder" >> {log:q}
        cp -a {output.background_file:q} {params.sync_dir:q} 2>> {log:q}
        cp -a {output.drift_file:q} {params.sync_dir:q} 2>> {log:q}
        echo "$(date -u): Finished copying background and drift files to sync folder" >> {log:q}
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
