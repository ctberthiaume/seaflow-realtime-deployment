#!/usr/bin/env python3
import os
import sys

import click
import yaml


@click.command()
@click.argument("datasource")
@click.argument("outpath")
def cmd(datasource, outpath):
    """Write a Grafana datasource configuration yaml file"""
    config = create_config(datasource)
    try:
        with open(outpath, "w", encoding="utf-8") as fh:
            fh.write(yaml.dump(config))
    except IOError as e:
        raise click.ClickException(
            "could not write output yaml file to {}: {}".format(outpath, str(e))
        )


def create_config(datasource):
    config = yaml.load(
        """# config file version
apiVersion: 1

datasources:
- name: DS
  type: postgres
  url: ${PGHOST}:${PGPORT}
  user: ${ROUSER}
  jsonData:
    # <string> database name, if used. As of 12.3 docs are wrong and say this is
    # a top-level field, but it acually needs to be in jsonData for postgres.
    # See https://github.com/grafana/grafana/issues/112418
    database: DB
    postgresVersion: 1800
    timescaledb: true
    maxOpenConns: 10
    maxIdleConns: 10
    maxIdleConnsAuto: true
    connMaxLifetime: 1800
    timeInterval: 1m
    sslmode: 'disable'
  secureJsonData:
    password: ${ROPASSWORD}
  version: 1
  # <bool> allow users to edit datasources from the UI.
  editable: true
""",
        Loader=yaml.FullLoader,
    )
    config["datasources"][0]["name"] = datasource
    config["datasources"][0]["uid"] = datasource
    config["datasources"][0]["jsonData"]["database"] = datasource
    return config


if __name__ == "__main__":
    cmd()  # type: ignore[call-arg]
