FROM golang:1.13-buster AS gobuild

WORKDIR /timescaledb-parallel-copy-build
RUN go mod init timescaledb-parallel-copy-build \
    && go get -d github.com/timescale/timescaledb-parallel-copy/cmd/timescaledb-parallel-copy@21e4eacdb07b0397c3d93931d7dbffced77f809f \
    && go build -o timescaledb-parallel-copy github.com/timescale/timescaledb-parallel-copy/cmd/timescaledb-parallel-copy

WORKDIR /tsdata-build
RUN go mod init tsdata-build \
    && go get -d github.com/ctberthiaume/tsdata/cmd/tsdata@v0.3.1 \
    && go build -o tsdata github.com/ctberthiaume/tsdata/cmd/tsdata

FROM python:3.8-buster

ARG DEBIAN_FRONTEND=noninteractive
ARG GF_UID="472"
ARG REALTIME_UID="1000"

# Install apt packages, make grafana user
RUN apt-get -qq update \
    && apt-get install -qq -y \
    postgresql-client \
    rclone \
    rsync \
    vim \
    2>&1 | grep -v "debconf: delaying package configuration, since apt-utils is not installed" \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -m -u $GF_UID grafana \
    && useradd -m -u $REALTIME_UID ubuntu

# Install Go tools from previous build stage
COPY --from=gobuild \
    /timescaledb-parallel-copy-build/timescaledb-parallel-copy \
    /tsdata-build/tsdata \
    /usr/local/bin/

# Install minio client
RUN curl --silent --show-error -o /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/archive/mc.RELEASE.2021-09-23T05-44-03Z \
    && chmod +x /usr/local/bin/mc

# Install python dependencies
COPY ./requirements.txt /app/
RUN pip install -q --no-cache-dir -r /app/requirements.txt

# Set up everything else
COPY \
    ./register_datasource.py \
    ./tsdata2sql.py \
    ./run.sh \
    /app/

RUN chmod +x /app/run.sh

WORKDIR /app/
USER grafana
CMD ["bash"]
