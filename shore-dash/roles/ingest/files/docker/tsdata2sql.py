#!/usr/bin/env python3
import os
import logging
import time

import click
import psycopg2
import tsdataformat
from psycopg2 import sql
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT

logger = logging.getLogger()

# ----------------------------------------
# These are required environment variables
# ----------------------------------------
# PGUSER = admin postgres user
# PGPASSWORD = admin postgres user's password
# PGHOST = postgres host address
# PGPORT = postgres host port
# ROUSER = read-only postgres user
# ROPASSWORD = read-ony postgres user's password

# -------------------------------------
# These can be set to override defaults
# -------------------------------------
# GEO_LABEL = label to identify geo coordinate file type and table
# LAT_LABEL = column name for latitude
# LON_LABEL = column name for longitude
# TIME_LABEL = column name for timestamp

# Some constants when creating queries
c = {
    "PGUSER": None,
    "PGPASSWORD": None,
    "PGHOST": None,
    "PGPORT": None,
    "ROUSER": None,
    "ROPASSWORD": None,
    "TIME_LABEL": "time",
    "GEO_LABEL": "geo",
    "LAT_LABEL": "lat",
    "LON_LABEL": "lon",
    "TIME_AGG": "1m",  # timescaledb time aggregation
}

# Lookup between tsdata and postgresql data types
# NOTE: would use integer for integer but integer is getting converted to
# "numeric" in postgresql and the postgresql/timescaledb grafana extension
# doesn't seem to find "numeric" fields.
typelu = {
    "text": "TEXT",
    "float": "DOUBLE PRECISION",
    "time": "TIMESTAMPTZ NOT NULL",
    "category": "TEXT",
    "integer": "DOUBLE PRECISION",
    "boolean": "BOOLEAN",
}


@click.command()
@click.option("-v", "--verbose", is_flag=True, show_default=True, default=False)
@click.argument("input-file", type=click.File("r"))
def sql_cmd(verbose, input_file):
    # Set up logging
    ch = logging.StreamHandler()
    if verbose:
        logger.setLevel(logging.DEBUG)
        ch.setLevel(logging.DEBUG)
    formatter = logging.Formatter(
        "%(asctime)s.%(msecs)03dZ - %(filename)s - %(levelname)s - %(message)s",
        "%Y-%m-%dT%H:%M:%S",
    )
    formatter.converter = time.gmtime
    ch.setFormatter(formatter)
    logger.addHandler(ch)

    # Required env vars
    for envvar in [
        "PGUSER",
        "PGPASSWORD",
        "PGHOST",
        "PGPORT",
        "ROUSER",
        "ROPASSWORD",
    ]:
        if not envvar in os.environ:
            raise click.ClickException("{} not set".format(envvar))
        c[envvar] = os.environ.get(envvar, c[envvar])

    # Optional env vars
    for envvar in ["GEO_LABEL", "LAT_LABEL", "LON_LABEL", "TIME_LABEL", "TIME_AGG"]:
        c[envvar] = os.environ.get(envvar, c[envvar])

    ts = tsdataformat.Tsdata()
    try:
        header_text = tsdataformat.read_header(input_file)
    except IOError as e:
        raise click.ClickException("could not read input file: {}".format(str(e)))
    try:
        ts.set_metadata_from_text(header_text)
    except ValueError as e:
        raise click.ClickException(
            "problem parsing input file header: {}".format(str(e))
        )

    dbname = ts.metadata["Project"]
    table = ts.metadata["FileType"]
    columns = ts.metadata["Headers"]
    types = ts.metadata["Types"]

    # Make sure geo table has float lat and lon columns
    # table/FileType should be named as GEO_LABEL or end with GEO_LABEL after
    # a hyphen. The table will be named GEO_LABEL in the database in both cases
    # to make it generally findable in the database.
    if table == c["GEO_LABEL"]:
        try:
            lati = columns.index(c["LAT_LABEL"])
            loni = columns.index(c["LON_LABEL"])
        except ValueError:
            raise click.ClickException(
                "{} and {} must be present in {} file".format(
                    c["LAT_LABEL"], c["LON_LABEL"], c["GEO_LABEL"]
                )
            )
        else:
            if types[lati] != "float" or types[loni] != "float":
                raise click.ClickException(
                    "{} and {} columns in a {} file must be floats".format(
                        c["LAT_LABEL"], c["LON_LABEL"], c["GEO_LABEL"]
                    )
                )

    try:
        create_database(dbname)
    except psycopg2.Error as e:
        raise click.ClickException(str(e))
    try:
        create_tables_and_views(dbname, table, columns, types)
    except psycopg2.Error as e:
        raise click.ClickException(str(e))


def create_database(dbname):
    conn = psycopg2.connect(
        user=c["PGUSER"], password=c["PGPASSWORD"], host=c["PGHOST"], port=c["PGPORT"],
    )
    try:
        # CREATE DATABASE has to happen outside a transaction so set autocommit
        conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)

        # There's a race condition between checking for db/user existence and
        # creation, so log errors on db/user creation but do continue with other
        # steps. If there was a significant problem creating the db and user
        # subsequent steps will throw fatal errors.

        # ----------------------------------
        # Create read-only user if necessary
        # ----------------------------------
        cur = conn.cursor()
        query = sql.SQL("SELECT count(1) FROM pg_roles WHERE rolname=%s")
        logger.debug(query.as_string(conn))
        cur.execute(query, (c["ROUSER"],))
        count = cur.fetchone()
        if count and count[0] == 0:
            try:
                query = sql.SQL(
                    "CREATE ROLE {} WITH LOGIN PASSWORD %s NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION VALID UNTIL 'infinity'".format(
                        c["ROUSER"]
                    )
                )
                logger.debug(query.as_string(conn))
                cur.execute(query, (c["ROPASSWORD"],))
                logger.info("Created user {}".format(c["ROUSER"]))
            except psycopg2.Error as e:
                # Might have been caused by user being created after above check
                # by some other process. Log a warning and continue.
                logger.warning(str(e))
        else:
            logger.debug("user {} already exists".format(c["ROUSER"]))
        cur.close()

        # -------------------------------------------
        # Create this project's database if necessary
        # -------------------------------------------
        cur = conn.cursor()
        query = sql.SQL(
            "SELECT count(1) FROM pg_catalog.pg_database WHERE datname = %s"
        )
        logger.debug(query.as_string(conn))
        cur.execute(query, (dbname,))
        count = cur.fetchone()
        if count and count[0] == 0:
            try:
                query = sql.SQL("CREATE DATABASE {}").format(sql.Identifier(dbname))
                logger.debug(query.as_string(conn))
                cur.execute(query)
                logger.info("Created database {}".format(dbname))
                # This script created the db, now grant connect privileges
                query = sql.SQL(
                    "GRANT CONNECT ON DATABASE {} TO %s" % c["ROUSER"]
                ).format(sql.Identifier(dbname))
                logger.debug(query.as_string(conn))
                cur.execute(query)
            except psycopg2.Error as e:
                # Might have been caused by db being created after above check
                # by some other process. Log a warning and continue.
                logger.warning(str(e))
        else:
            logger.debug("db {} already exists".format(dbname))
        cur.close()
    finally:
        conn.close()

    # -----------------------------------------------------------------
    # Configure timescaledb and permissions for this project's database
    # -----------------------------------------------------------------
    conn = psycopg2.connect(
        user=c["PGUSER"],
        host=c["PGHOST"],
        port=c["PGPORT"],
        password=c["PGPASSWORD"],
        dbname=dbname,
    )
    try:
        with conn:
            with conn.cursor() as cur:
                # timescaledb extension
                query = sql.SQL("CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE")
                logger.debug(query.as_string(conn))
                cur.execute(query)

                # Set permissions for read-only user
                query = sql.SQL(
                    "GRANT USAGE ON SCHEMA public TO {}".format(c["ROUSER"])
                )
                logger.debug(query.as_string(conn))
                cur.execute(query)
                query = sql.SQL(
                    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO {}".format(
                        c["ROUSER"]
                    )
                )
                logger.debug(query.as_string(conn))
                cur.execute(query)
                query = sql.SQL(
                    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO {}".format(
                        c["ROUSER"]
                    )
                )
                logger.debug(query.as_string(conn))
                cur.execute(query)
    except psycopg2.Error as e:
        # Error may be because another process is already creating extension or
        # updating priviliges
        logger.warning(
            "Error during timescaledb and user permissions config on {}, rolling back transaction".format(
                dbname
            )
        )
        logger.warning(str(e))
    finally:
        conn.close()


def create_tables_and_views(dbname, table, columns, types):
    pgtypes = [typelu[t] for t in types]  # tsdata types to postgresql types
    conn = psycopg2.connect(
        user=c["PGUSER"],
        host=c["PGHOST"],
        port=c["PGPORT"],
        password=c["PGPASSWORD"],
        dbname=dbname,
    )
    try:
        with conn:
            with conn.cursor() as cur:
                # ---------
                # Raw table
                # ---------
                raw_table = table + "_raw"
                # First create column / type pairs
                column_sql_parts = []
                for col, pgtype in zip(columns, pgtypes):
                    column_sql_parts.append(
                        sql.SQL("{} " + pgtype).format(sql.Identifier(col))
                    )
                query = sql.SQL(
                    "CREATE TABLE IF NOT EXISTS {table} ({column_sql})"
                ).format(
                    table=sql.Identifier(raw_table),
                    column_sql=sql.SQL(", ").join(column_sql_parts),
                )
                logger.debug(query.as_string(conn))
                cur.execute(query)
                # timescaledb hypertable
                query = sql.SQL(
                    "SELECT create_hypertable('\"{table}\"', '{time}', if_not_exists := true);".format(
                        table=raw_table, time=c["TIME_LABEL"]
                    )
                )
                logger.debug(query.as_string(conn))
                cur.execute(query)
                logger.info("Created table {}".format(raw_table))

        with conn:
            with conn.cursor() as cur:
                # time binned view
                groupby_cols = []  # track index of grouping columns
                select_sql_parts = []
                i = 1
                time_i = None
                for col, tsdatatype in zip(columns, types):
                    if tsdatatype == "text":
                        # Can't aggregate non-groupby text to just leave it out
                        continue
                    elif tsdatatype == "time" and col == c["TIME_LABEL"]:
                        item = sql.SQL(
                            "time_bucket('{timeagg}', {table}.{time}) AS {time}"
                        ).format(
                            timeagg=sql.SQL(c["TIME_AGG"]),
                            table=sql.Identifier(raw_table),
                            time=sql.Identifier(col),
                        )
                        time_i = i
                        groupby_cols.append(str(i))
                    elif tsdatatype == "category" or tsdatatype == "boolean":
                        item = sql.SQL("{}").format(sql.Identifier(col))
                        groupby_cols.append(str(i))
                    else:
                        item = sql.SQL("AVG({}) AS {}").format(
                            sql.Identifier(col), sql.Identifier(col)
                        )
                    select_sql_parts.append(item)
                    i += 1
                assert time_i != None
                select_sql = sql.SQL(", ").join(select_sql_parts)
                groupby_sql = sql.SQL(", ".join(groupby_cols))
                query = sql.SQL(
                    "CREATE OR REPLACE VIEW {table} AS SELECT {select_sql} FROM {parent} GROUP BY {groupby} ORDER BY {time_i}"
                ).format(
                    table=sql.Identifier(table),
                    select_sql=select_sql,
                    parent=sql.Identifier(raw_table),
                    groupby=groupby_sql,
                    time_i=sql.SQL(str(time_i)),
                )
                logger.debug(query.as_string(conn))
                cur.execute(query)
                logger.info("Created view {}".format(table))

        with conn:
            with conn.cursor() as cur:
                # geo joined view if a geo table already exists in this database
                if table != c["GEO_LABEL"]:
                    query = sql.SQL("SELECT to_regclass('{geo}')").format(
                        geo=sql.Identifier(c["GEO_LABEL"])
                    )
                    logger.info(query.as_string(conn))
                    cur.execute(query)
                    answer = cur.fetchone()
                    geo_exists = answer and bool(answer[0])
                    if not geo_exists:
                        logger.debug(
                            "{} table not found, skipping geo-joined view creation".format(
                                c["GEO_LABEL"]
                            )
                        )
                        return
                    else:
                        logger.debug(
                            "{} table found, creating geo-joined view".format(
                                c["GEO_LABEL"]
                            )
                        )

                    select_sql_parts = []
                    i = 1
                    time_i = None
                    for col, tsdatatype in zip(columns, types):
                        if tsdatatype == "text":
                            # Can't aggregate non-groupby text to just leave it out
                            continue
                        elif col == c["LAT_LABEL"] or col == c["LON_LABEL"]:
                            # rename lat / lon in table to distinguish from joined
                            # coords
                            col_alias = table + "_" + col
                            item = sql.SQL("a.{} AS {}").format(sql.Identifier(col), sql.Identifier(col_alias))
                        elif tsdatatype == "time" and col == c["TIME_LABEL"]:
                            time_i = i
                            item = sql.SQL("a.{}").format(sql.Identifier(col))
                        else:
                            item = sql.SQL("a.{}").format(sql.Identifier(col))
                        select_sql_parts.append(item)
                        i += 1
                    select_sql_parts.append(
                        sql.SQL("b.{}").format(sql.Identifier(c["LAT_LABEL"]))
                    )
                    select_sql_parts.append(
                        sql.SQL("b.{}").format(sql.Identifier(c["LON_LABEL"]))
                    )
                    select_sql = sql.SQL(", ").join(select_sql_parts)
                    query = sql.SQL(
                        "CREATE OR REPLACE VIEW {table} AS SELECT {select_sql} FROM {parent} AS a INNER JOIN {geo} as b on a.{time} = b.{time} ORDER BY {time_i}"
                    ).format(
                        table=sql.Identifier(table + "_geo"),
                        select_sql=select_sql,
                        parent=sql.Identifier(table),
                        geo=sql.Identifier(c["GEO_LABEL"]),
                        time=sql.Identifier(c["TIME_LABEL"]),
                        time_i=sql.SQL(str(time_i)),
                    )
                    logger.debug(query.as_string(conn))
                    cur.execute(query)
                    logger.info("Created geo-joined view {}".format(table + "_geo"))
    except psycopg2.Error as e:
        logger.error(
            "Error during tables/views creation for {}, rolling back transaction".format(
                table
            )
        )
        raise e
    finally:
        conn.close()


if __name__ == "__main__":
    sql_cmd()  # pylint: disable=no-value-for-parameter

