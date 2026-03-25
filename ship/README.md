## Install

### Miniforge / conda / mamba

Replace the miniforge installer URL wtih `https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Darwin-arm64.sh` on Apple Silicon Mac, or `https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Darwin-x86_64.sh` for Intel Mac.

```sh
curl -LO https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
bash Miniforge3-Linux-x86_64.sh -b -p $PWD/conda
source ./conda/bin/activate
eval "$(mamba shell hook --shell bash)"
```

### Snakemake

Create and activate a new conda/mamba environment and install some useful packages

```sh
conda create -c conda-forge -c bioconda -c nodefaults -n snakemake snakemake
conda activate snakemake
```
