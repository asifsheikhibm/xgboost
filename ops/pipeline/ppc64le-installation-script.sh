#!/bin/bash
set -euo pipefail

## Basic tools (from install_drivers.sh)
sudo apt-get update
sudo apt-get install -y cmake git build-essential wget ca-certificates curl unzip python3 python3-pip python3-venv

pip3 install --break-system-packages 'pip>=23' 'wheel>=0.42' pydistcheck

# Install aws cli v1 using pip
pip3 install awscli

## Install jq and yq
sudo apt update && sudo apt install jq
mkdir yq
pushd yq/
wget -nv https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_ppc64le.tar.gz -O - | \
    tar xz && sudo mv ./yq_linux_ppc64le /usr/bin/yq
popd
rm -rf yq/