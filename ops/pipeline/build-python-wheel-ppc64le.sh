#!/bin/bash
# Build Python wheels, CPU variant for ppc64le (no Docker)
# Runs directly on the ppc64le runner; requires the runner to be a
# manylinux_2_28-compatible environment so auditwheel can verify the ABI.

set -euo pipefail

WHEEL_TAG="manylinux_2_38_ppc64le"

source ops/pipeline/classify-git-branch.sh

echo "--- Build binary wheel for ${WHEEL_TAG} (CPU only)"
set -x

# Patch pyproject.toml to rename package to xgboost-cpu
python3 ops/script/pypi_variants.py --use-suffix=cpu --require-nccl-dep=na

# Build the wheel directly on the host Python
cd python-package
python3 -m pip wheel --no-deps -v . --wheel-dir dist/
cd ..

# Audit and repair the wheel for manylinux_2_28_ppc64le compliance
auditwheel repair --only-plat \
  --plat ${WHEEL_TAG} \
  python-package/dist/xgboost_cpu-*.whl \
  --wheel-dir wheelhouse/

# Retag to py3-none (language/ABI-neutral) for broad Python version compatibility
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