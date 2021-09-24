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

# list of datasources that should be deleted from the database
#deleteDatasources:
#  - name: Graphite
#    orgId: 1

# list of datasources to insert/update depending
# what's available in the database
datasources:
  # <string, required> name of the datasource. Required
- name: DS
  # <string, required> datasource type. Required
  type: postgres
  # <string, required> access mode. proxy or direct (Server or Browser in the UI). Required
  access: proxy
  # <int> org id. will default to orgId 1 if not specified
  orgId: 1
  # <string> url
  url: ${PGHOST}:${PGPORT}
  # <string> database user, if used
  user: ${ROUSER}
  # <string> database name, if used
  database: DB
  # <bool> enable/disable basic auth
  basicAuth:
  # <string> basic auth username
  basicAuthUser:
  # <string> basic auth password
  basicAuthPassword:
  # <bool> enable/disable with credentials headers
  withCredentials:
  # <bool> mark as default datasource. Max one per org
  isDefault:
  # <map> fields that will be converted to json and stored in jsonData
  jsonData:
    postgresVersion: 1200
    timescaledb: true
    maxOpenConns: unlimited
    maxIdleConns: 2
    connMaxLifetime: 14400
    timeInterval: 1m
    sslmode: disable
  secureJsonData:
    password: ${ROPASSWORD}
  version: 1
  # <bool> allow users to edit datasources from the UI.
  editable: true
""",
        Loader=yaml.FullLoader,
    )
    config["datasources"][0]["name"] = datasource
    config["datasources"][0]["database"] = datasource
    return config


if __name__ == "__main__":
    cmd()  # pylint: disable=no-value-for-parameter
