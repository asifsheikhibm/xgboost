#!/bin/bash
# Build Python wheels, CPU variant for ppc64le
# Uses the manylinux_2_28_ppc64le container for ABI-compatible compilation.

set -euo pipefail

WHEEL_TAG="manylinux_2_28_ppc64le"
IMAGE_URI="icr.io/rhoai-cicd/xgb-manylinux_2_28_ppc64le:latest"
PYTHON_BIN="/opt/python/cp312-cp312/bin/python"

source ops/pipeline/classify-git-branch.sh

echo "--- Build binary wheel for ${WHEEL_TAG} (CPU only)"
set -x

# Patch pyproject.toml to rename package to xgboost-cpu
python3 ops/script/pypi_variants.py --use-suffix=cpu --require-nccl-dep=na

# Build inside the manylinux_2_28 container (old toolchain = glibc-2.28-compatible symbols)
python3 ops/docker_run.py \
  --image-uri "${IMAGE_URI}" \
  -- bash -c \
  "cd python-package && ${PYTHON_BIN} -m pip wheel --no-deps -v . --wheel-dir dist/"

# Audit and repair inside the same container
python3 ops/docker_run.py \
  --image-uri "${IMAGE_URI}" \
  -- auditwheel repair --only-plat \
  --plat ${WHEEL_TAG} python-package/dist/xgboost_cpu-*.whl

# Retag to py3-none for broad Python version compatibility
python3 -m wheel tags --python-tag py3 --abi-tag none --platform ${WHEEL_TAG} --remove \
  wheelhouse/xgboost_cpu-*.whl

# Promote repaired wheel to dist/, discard raw wheel
rm -v python-package/dist/xgboost_cpu-*.whl
mv -v wheelhouse/xgboost_cpu-*.whl python-package/dist/

# Verify libgomp was vendored in
if ! unzip -l python-package/dist/*.whl | grep libgomp > /dev/null; then
  echo "error: libgomp.so was not vendored in the wheel"
  exit 1
fi

# Check wheel size against project limits
pydistcheck --config python-package/pyproject.toml python-package/dist/*.whl

if [[ ($is_pull_request == 0) && ($is_release_branch == 1) ]]; then
  python3 ops/pipeline/manage-artifacts.py upload \
    --s3-bucket xgboost-nightly-builds \
    --prefix ${BRANCH_NAME}/${GITHUB_SHA} --make-public \
    python-package/dist/*.whl
fi