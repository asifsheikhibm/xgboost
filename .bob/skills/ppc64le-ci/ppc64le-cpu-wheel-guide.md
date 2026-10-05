# ppc64le CPU-Only Wheel Generation and Test — Implementation Guide

## 1. Objective

Add a ppc64le CPU-only Python wheel build job (`xgboost-cpu`) and a corresponding wheel test job to the XGBoost CI pipeline. The deliverables are:

1. A new `manylinux_2_28_ppc64le` container image (build context in `xgboost-devops`).
2. A new `xgb-ci.manylinux_2_28_ppc64le` ECR image entry in `ci_container.yml`.
3. A new Conda environment file `ppc64le_test.yml` for the test container.
4. A new `Dockerfile.manylinux_2_28_ppc64le` mirroring the aarch64 pattern.
5. A new matrix `include` entry in `build-python-wheels-cpu` in `.github/workflows/main.yml`.
6. A conditional `runs-on` in `build-python-wheels-cpu` so ppc64le uses the community
   self-hosted `ubuntu-24.04-ppc64le` runner instead of the runs-on SaaS service.
7. A new `test-python-wheel-cpu-ppc64le` job in `.github/workflows/main.yml`.
8. A new `cpu-ppc64le` suite branch in `ops/pipeline/test-python-wheel.sh`.
9. A `ppc64le` case in `containers/scripts/install_gosu.sh` — a **blocker** today.

**Target runner:** `ubuntu-24.04-ppc64le` (community self-hosted; IBM Power — not available on AWS)

---

## 2. Workflows and Files Analysed

| File | Relevant Job(s) |
|---|---|
| `xgboost/.github/workflows/main.yml` | `build-python-wheels-cpu`, `test-python-wheel-cpu` |
| `xgboost/.github/workflows/ci_configure.yml` | `ci-configure` |
| `xgboost-devops/.github/workflows/containers.yml` | `build-containers` |
| `xgboost-devops/.github/runs-on.yml` | runner definitions |
| `xgboost/ops/pipeline/build-python-wheels-cpu.sh` | wheel builder |
| `xgboost/ops/pipeline/test-python-wheel.sh` | wheel tester |
| `xgboost-devops/containers/ci_container.yml` | image catalog |
| `xgboost-devops/containers/dockerfile/Dockerfile.manylinux_2_28_aarch64` | aarch64 manylinux image (reference) |
| `xgboost-devops/containers/scripts/install_gosu.sh` | gosu installer |

---

## 3. Current Workflow Structure

```
XGBoost CI (main.yml)
 ├── ci-configure            (ECR login, image tag)
 ├── build-python-wheels-cpu (matrix: manylinux_2_28 × {x86_64, aarch64})
 │    └── uses build-python-wheels-cpu.sh
 │         └── docker_run.py → xgb-ci.manylinux_2_28_{arch}:main
 ├── test-python-wheel-cpu   (matrix: {CPU-amd64, CPU-arm64})
 │    └── uses test-python-wheel.sh --suite {cpu, cpu-arm64}
 │    └── needs: [ci-configure, audit-cuda-wheel]    ← uses CUDA wheel for CPU testing
 └── ... (GPU jobs, macOS, etc.)

Container build pipeline (containers.yml in xgboost-devops)
 ├── amd64 containers (runner: linux-amd64-cpu)
 └── arm64 containers via include entries (runner: linux-arm64-cpu)
```

**Key observations:**

- `build-python-wheels-cpu` runs **without** `ci-configure` — it logs into ECR itself via
  `login-docker-registry.sh` and constructs the image URI from `arch` directly.
- `test-python-wheel-cpu` depends on `audit-cuda-wheel` and uses the CUDA 13 x86_64/aarch64
  wheel as the artifact source. For ppc64le there is no CUDA wheel; the artifact to test is
  the `xgboost-cpu` wheel produced by `build-python-wheels-cpu`. The dependency chain differs,
  so a separate test job is cleaner.
- The aarch64 pattern (separate `include` entry, dedicated runner) is the direct reference to
  follow for ppc64le.
- **Critically**: the current `runs-on` block is a hardcoded multi-label list that references
  the runs-on SaaS service. ppc64le must bypass this entirely and use a plain self-hosted
  runner label (`ubuntu-24.04-ppc64le`). This requires restructuring `runs-on` with `fromJSON`.

---

## 4. Recommended Implementation

**Approach: separate `include` entries** added to the existing matrices in `build-python-wheels-cpu`
and a **new dedicated test job** `test-python-wheel-cpu-ppc64le`.

**Why not expand the main matrix dimension?**

Adding `ppc64le` as a bare matrix dimension would multiply every existing CPU combination
needlessly. The existing pattern already uses targeted `include` entries to represent
aarch64 — follow that same minimal approach.

**Why a separate test job instead of extending `test-python-wheel-cpu`?**

`test-python-wheel-cpu` depends on `audit-cuda-wheel` and uses the CUDA 13 x86_64/aarch64
wheel as the artifact source. For ppc64le there is no CUDA wheel; the artifact to test is
the `xgboost-cpu` wheel produced by `build-python-wheels-cpu`. The dependency chain and the
artifact stash prefix differ, making a separate job the cleanest approach.

---

## 5. Required Changes

### Change 1 — Fix `install_gosu.sh` to support ppc64le (blocker)

**File**
```
xgboost-devops/containers/scripts/install_gosu.sh
```

**Location**

Lines 10–24 — the `case "${arch}"` block and the checksum table.

**Current behavior**

The script maps host architectures to gosu binary names. It handles `x86_64`, `aarch64`, and
`i386` but has no `ppc64le` branch:

```bash
case "${arch}" in
  x86_64 | amd64)  gosu_arch="amd64" ;;
  aarch64 | arm64) gosu_arch="arm64" ;;
  i386 | i686)     gosu_arch="i386"  ;;
  *)
    echo "Unsupported gosu architecture: ${arch}" >&2
    exit 1
    ;;
esac
```

The script also hard-codes SHA-256 checksums per version/arch combination. Without a
`ppc64le` entry in the checksum table, even adding the arch mapping will fail.

**Required change**

1. Add `ppc64le` arch mapping.
2. Add the SHA-256 checksum for `gosu-ppc64le` at `GOSU_VERSION=1.10`.

**Suggested implementation**

```bash
case "${arch}" in
  x86_64 | amd64)  gosu_arch="amd64"   ;;
  aarch64 | arm64) gosu_arch="arm64"   ;;
  i386 | i686)     gosu_arch="i386"    ;;
  ppc64le)         gosu_arch="ppc64le" ;;
  *)
    echo "Unsupported gosu architecture: ${arch}" >&2
    exit 1
    ;;
esac
```

And in the checksum table:

```bash
case "${GOSU_VERSION}:${gosu_arch}" in
  1.10:amd64)   gosu_sha256="5b3b03713a888cee84ecbf4582b21ac9fd46c3d935ff2d7ea25dd5055d302d3c" ;;
  1.10:arm64)   gosu_sha256="3ebbff47692c3d9f0c3b6500727e277cb23d621feebcac0cc3d9e382d62d1acb" ;;
  1.10:i386)    gosu_sha256="2dfac0dd8830ebccea486d90472b48e68de5a543d9fb50bea933bbe6a9c8d610" ;;
  1.10:ppc64le) gosu_sha256="<SHA256_FROM_GOSU_RELEASE>"  ;;  # Requires validation
  *)
    echo "Unsupported gosu version/architecture: ${GOSU_VERSION}/${gosu_arch}" >&2
    exit 1
    ;;
esac
```

> ⚠️ **Requires validation**: Retrieve the correct SHA-256 for `gosu-ppc64le` version `1.10`
> from the [gosu GitHub releases page](https://github.com/tianon/gosu/releases/tag/1.10).
> Verify the file `gosu-ppc64le` exists for that release before using it.

**Reason**

Every container image built for XGBoost CI installs gosu via this script. Without ppc64le
support here, no ppc64le container image can be built.

**Priority**: Required (blocker — must be resolved before any container can be built)

---

### Change 2 — Create `Dockerfile.manylinux_2_28_ppc64le`

**File (new)**
```
xgboost-devops/containers/dockerfile/Dockerfile.manylinux_2_28_ppc64le
```

**Location**

New file alongside `Dockerfile.manylinux_2_28_aarch64`.

**Current behavior**

No ppc64le manylinux image exists. The aarch64 Dockerfile is the closest reference.

**Required change**

Create a new Dockerfile modelled directly on the aarch64 one, substituting `aarch64` → `ppc64le`
throughout. Note key differences:

- The upstream image is `quay.io/pypa/manylinux_2_28_ppc64le` (verify this tag exists on quay.io/pypa).
- The Miniforge installer binary is `Miniforge3-...-Linux-ppc64le.sh`.
- GCC toolset paths in the manylinux_2_28 images follow the same pattern as aarch64.
- The `aarch64_test` conda environment is replaced with `ppc64le_test` (see Change 3).

**Suggested implementation**

```dockerfile
FROM quay.io/pypa/manylinux_2_28_ppc64le
ARG MINIFORGE_VERSION=26.3.2-3

SHELL ["/bin/bash", "-c"]

ENV PATH=/opt/miniforge/bin:$PATH
ENV CC=/opt/rh/gcc-toolset-10/root/usr/bin/gcc
ENV CXX=/opt/rh/gcc-toolset-10/root/usr/bin/c++
ENV CPP=/opt/rh/gcc-toolset-10/root/usr/bin/cpp
ENV GOSU_VERSION=1.10

COPY scripts/install_gosu.sh /scripts/

RUN \
    dnf -y update && \
    dnf -y install dnf-plugins-core && \
    dnf config-manager --set-enabled powertools && \
    dnf install -y tar unzip wget xz git which ninja-build java-17-openjdk-devel \
                   gcc-toolset-10-gcc gcc-toolset-10-binutils gcc-toolset-10-gcc-c++ && \
    # Miniforge
    wget -nv -O conda.sh \
      https://github.com/conda-forge/miniforge/releases/download/$MINIFORGE_VERSION/Miniforge3-$MINIFORGE_VERSION-Linux-ppc64le.sh && \
    bash conda.sh -b -p /opt/miniforge

# Create new Conda environment
COPY conda_env/ppc64le_test.yml /scripts/
RUN mamba create -n ppc64le_test && \
    mamba env update -n ppc64le_test --file=/scripts/ppc64le_test.yml && \
    mamba clean --all --yes

# Install lightweight sudo (not bound to TTY)
RUN sh /scripts/install_gosu.sh

# Default entry-point to use if running locally
COPY entrypoint.sh /scripts/

WORKDIR /workspace
ENTRYPOINT ["/scripts/entrypoint.sh"]
```

> ⚠️ **Requires validation**:
> - Confirm `quay.io/pypa/manylinux_2_28_ppc64le` is published and has the same GCC toolset layout.
> - Confirm `Miniforge3-26.3.2-3-Linux-ppc64le.sh` is available from conda-forge releases.
> - Confirm `gcc-toolset-10` is available in the manylinux_2_28_ppc64le dnf repos.

**Reason**

`build-python-wheels-cpu.sh` constructs the image URI as `xgb-ci.manylinux_2_28_${arch}` and
invokes `docker run` via `docker_run.py`. The image must exist in ECR before the wheel build
job can run.

**Priority**: Required

---

### Change 3 — Create `ppc64le_test.yml` Conda environment

**File (new)**
```
xgboost-devops/containers/conda_env/ppc64le_test.yml
```

**Location**

New file alongside `aarch64_test.yml`.

**Suggested implementation**

```yaml
name: ppc64le_test
channels:
- conda-forge
dependencies:
- python=3.12
- pip
- wheel
- pytest
- pytest-cov
- numpy
- scipy
- scikit-learn
- pandas
- matplotlib
- dask
- distributed
- hypothesis
- graphviz
- python-graphviz
- cmake
- ninja
- jsonschema
- boto3
- loky>=3.5.1
- pyarrow
# PySpark
- pyspark>=4.0
- grpcio
- grpcio-status
- googleapis-common-protos
- zstandard
- cloudpickle
- pip:
  - awscli
  - auditwheel
```

> ⚠️ **Requires validation**: Not all packages in `aarch64_test.yml` may have ppc64le
> conda-forge packages (e.g. `numba`, `llvmlite`). Review availability on conda-forge for
> `linux-ppc64le`. The list above omits `numba`/`llvmlite`/`codecov` as a precaution — add
> them back if confirmed available.

**Reason**

`auditwheel` (used to validate the built wheel complies with `manylinux_2_28_ppc64le`) and
`pytest` (used in the test job) must be present in the container.

**Priority**: Required

---

### Change 4 — Register `xgb-ci.manylinux_2_28_ppc64le` in `ci_container.yml`

**File**
```
xgboost-devops/containers/ci_container.yml
```

**Location**

After the `xgb-ci.manylinux_2_28_aarch64` entry (after line 101).

**Required change**

```yaml
xgb-ci.manylinux_2_28_ppc64le:
  container_def: manylinux_2_28_ppc64le
```

**Reason**

`docker_build.sh` reads `ci_container.yml` to find `container_def` and `build_args` for every
image it builds. The new Dockerfile will not be built by the container pipeline until it is
registered here.

**Priority**: Required

---

### Change 5 — Add ppc64le entry to the `build-containers` matrix

**File**
```
xgboost-devops/.github/workflows/containers.yml
```

**Location**

The `strategy.matrix.include` block (after the last existing `include` entry).

**Required change**

```yaml
include:
  # ... existing aarch64 entries ...
  - image_repo: xgb-ci.manylinux_2_28_ppc64le
    runner: linux-ppc64le-cpu
```

**Reason**

Without this entry the container is never built and pushed to ECR.

**Priority**: Required

---

### Change 6 — Restructure `runs-on` in `build-python-wheels-cpu` to support both SaaS and self-hosted runners

**File**
```
xgboost/.github/workflows/main.yml
```

**Location**

`jobs.build-python-wheels-cpu.runs-on` and `strategy.matrix.include` (lines 261–278).

**Background — why this change is necessary**

AWS does not offer ppc64le (IBM Power) instances. The `ubuntu-24.04-ppc64le` runner is
provided by the community and registered as a plain GitHub Actions self-hosted runner label.
It does **not** use the runs-on SaaS service.

The current `runs-on` block is a hardcoded multi-label list that always invokes the runs-on
SaaS service:

```yaml
runs-on:
  - runs-on                                   # ← SaaS service entry-point
  - runner=${{ matrix.runner }}
  - run-id=${{ github.run_id }}
  - tag=main-build-python-wheels-cpu-...
```

Sending a ppc64le job through this list would cause runs-on to attempt to dispatch to an
AWS ppc64le instance that does not exist, and the job would fail.

The ppc64le entry must instead resolve to the plain string `"ubuntu-24.04-ppc64le"` — a
self-hosted runner label — with no runs-on SaaS labels at all.

**Solution — `fromJSON` with a matrix `runs_on` variable**

GitHub Actions evaluates `runs-on` before the job runs. It accepts either:
- a plain string, e.g. `runs-on: ubuntu-24.04`
- a list of strings (label matching), e.g. `runs-on: [self-hosted, linux-ppc64le]`

The idiomatic way to make `runs-on` conditional per matrix entry is to store the entire
`runs-on` value as a JSON-encoded string in a matrix variable and decode it with `fromJSON()`:

```yaml
runs-on: ${{ fromJSON(matrix.runs_on) }}
```

- For x86_64 and aarch64, `matrix.runs_on` holds a JSON array — `fromJSON` expands it to the
  multi-label list expected by the runs-on SaaS service.
- For ppc64le, `matrix.runs_on` holds a JSON string — `fromJSON` expands it to the plain
  string `"ubuntu-24.04-ppc64le"`.

**Current behavior**

```yaml
  build-python-wheels-cpu:
    name: Build CPU wheel (xgboost-cpu) for ${{ matrix.manylinux_target }}_${{ matrix.arch }}
    runs-on:
      - runs-on
      - runner=${{ matrix.runner }}
      - run-id=${{ github.run_id }}
      - tag=main-build-python-wheels-cpu-${{ matrix.manylinux_target }}-${{ matrix.arch }}
    strategy:
      fail-fast: false
      matrix:
        include:
        - manylinux_target: manylinux_2_28
          arch: aarch64
          runner: linux-arm64-cpu
        - manylinux_target: manylinux_2_28
          arch: x86_64
          runner: linux-amd64-cpu
        - manylinux_target: manylinux_2_28
          arch: ppc64le
          runner: linux-ppc64le-cpu
```

**Required change**

Replace the static multi-label `runs-on` block with a `fromJSON` expression, move the full
`runs-on` value into each matrix entry as `runs_on`, and remove the now-unused `runner`
field. The ppc64le entry carries a plain JSON string; x86_64/aarch64 entries carry JSON arrays.

```yaml
  build-python-wheels-cpu:
    name: Build CPU wheel (xgboost-cpu) for ${{ matrix.manylinux_target }}_${{ matrix.arch }}
    # ppc64le uses a community self-hosted runner (ubuntu-24.04-ppc64le); AWS x86_64 and
    # aarch64 use the runs-on SaaS service. fromJSON() lets runs-on resolve to either a
    # plain string (ppc64le) or a label list (x86_64/aarch64) from the same expression.
    runs-on: ${{ fromJSON(matrix.runs_on) }}
    strategy:
      fail-fast: false
      matrix:
        include:
        - manylinux_target: manylinux_2_28
          arch: aarch64
          runs_on: '["runs-on", "runner=linux-arm64-cpu", "run-id=${{ github.run_id }}", "tag=main-build-python-wheels-cpu-manylinux_2_28-aarch64"]'
        - manylinux_target: manylinux_2_28
          arch: x86_64
          runs_on: '["runs-on", "runner=linux-amd64-cpu", "run-id=${{ github.run_id }}", "tag=main-build-python-wheels-cpu-manylinux_2_28-x86_64"]'
        - manylinux_target: manylinux_2_28
          arch: ppc64le
          runs_on: '"ubuntu-24.04-ppc64le"'
```

**How each entry resolves at runtime**

| arch | `matrix.runs_on` value | After `fromJSON()` | Result |
|---|---|---|---|
| `aarch64` | JSON array `[...]` | list of strings | runs-on SaaS dispatches to `linux-arm64-cpu` |
| `x86_64` | JSON array `[...]` | list of strings | runs-on SaaS dispatches to `linux-amd64-cpu` |
| `ppc64le` | JSON string `"ubuntu-24.04-ppc64le"` | plain string | GitHub dispatches to self-hosted runner with that label |

**Important note on expression syntax in matrix strings**

The `${{ github.run_id }}` context expression inside the `runs_on` string values is evaluated
by GitHub Actions before the matrix is applied, so it expands correctly. The surrounding
single quotes are YAML quoting for the outer string; the inner double quotes are JSON.

**Reason**

Without this change, the ppc64le matrix entry would inherit the runs-on SaaS labels from the
parent `runs-on` block, causing the job to fail because AWS has no ppc64le runners. This is
the minimal restructuring that makes x86_64/aarch64 behaviour identical to today while
routing ppc64le to the correct self-hosted runner.

**Priority**: Required

---

### Change 7 — Add stash step for the ppc64le wheel in `build-python-wheels-cpu`

**File**
```
xgboost/.github/workflows/main.yml
```

**Location**

`jobs.build-python-wheels-cpu.steps`, after the existing build step.

**Current behavior**

`build-python-wheels-cpu` does not stash the produced wheel to the S3 run cache. It only
uploads to the `xgboost-nightly-builds` public bucket on release branches. The test job
therefore has no way to retrieve the wheel within the same run.

**Required change**

Add a conditional upload step using `actions/upload-artifact` (no S3 dependency on the
ppc64le runner, which is self-hosted and may not have `RUNS_ON_S3_BUCKET_CACHE` available):

```yaml
      - name: Upload xgboost-cpu wheel (ppc64le)
        if: matrix.arch == 'ppc64le'
        uses: actions/upload-artifact@v7.0.1
        with:
          name: xgboost-cpu-ppc64le-wheel
          path: python-package/dist/*.whl
          retention-days: 1
```

**Reason**

Without a stash or upload step there is no mechanism to pass the wheel between the build job
and the test job within the same workflow run.

**Priority**: Required

---

### Change 8 — Add `cpu-ppc64le` suite to `test-python-wheel.sh`

**File**
```
xgboost/ops/pipeline/test-python-wheel.sh
```

**Location**

Three sections: the suite validation `case` block (lines 41–46), the conda environment
activation `case` block (lines 73–80), and the test runner `case` block (lines 109–139).

**Current behavior**

```bash
# Validation
case "${suite}" in
  gpu|mgpu|gpu-arm64|cpu|cpu-arm64) ;;
  *) echo "Error: unsupported suite"; exit 1 ;;
esac

# Activation
case "$suite" in
  gpu|mgpu|gpu-arm64)  source activate gpu_test ;;
  cpu|cpu-arm64)       source activate linux_cpu_test ;;
esac

# Tests (cpu-arm64 case)
  cpu-arm64)
    pytest -v -s -rxXs --durations=0 \
      tests/python/test_basic.py tests/python/test_basic_models.py \
      tests/python/test_model_compatibility.py
    ;;
```

**Required change**

```bash
# Validation — add cpu-ppc64le
case "${suite}" in
  gpu|mgpu|gpu-arm64|cpu|cpu-arm64|cpu-ppc64le) ;;
  *)
    echo "Error: --suite must be one of: gpu, mgpu, gpu-arm64, cpu, cpu-arm64, cpu-ppc64le. Got '${suite}'"
    exit 1 ;;
esac

# Activation — add cpu-ppc64le
case "$suite" in
  gpu|mgpu|gpu-arm64)  source activate gpu_test ;;
  cpu|cpu-arm64)       source activate linux_cpu_test ;;
  cpu-ppc64le)         source activate ppc64le_test ;;
esac

# Tests — add cpu-ppc64le case
  cpu-ppc64le)
    echo "-- Run Python tests (CPU, ppc64le)"
    pytest -v -s -rxXs --durations=0 \
      tests/python/test_basic.py tests/python/test_basic_models.py \
      tests/python/test_model_compatibility.py
    ;;
```

> **Note**: The subset of tests (`test_basic`, `test_basic_models`, `test_model_compatibility`)
> follows the same conservative scope as `cpu-arm64`. Expand the test suite once the runner is
> confirmed stable. PySpark and Dask tests are excluded initially until their availability on
> ppc64le conda-forge is validated.

**Reason**

The test script rejects unknown suite names. Without adding `cpu-ppc64le`, the workflow step
will fail immediately on the validation check.

**Priority**: Required

---

### Change 9 — Add `test-python-wheel-cpu-ppc64le` job to `main.yml`

**File**
```
xgboost/.github/workflows/main.yml
```

**Location**

New job, after `test-python-wheel-cpu` (after line 548).

**Required change**

```yaml
  test-python-wheel-cpu-ppc64le:
    name: Python tests CPU (ppc64le, xgboost-cpu wheel)
    needs: build-python-wheels-cpu
    runs-on: ubuntu-24.04-ppc64le
    timeout-minutes: 60
    container:
      image: 492475357299.dkr.ecr.us-west-2.amazonaws.com/xgb-ci.manylinux_2_28_ppc64le:main
      options: "--init"
    steps:
      - uses: actions/checkout@v7.0.1
      - name: Download xgboost-cpu wheel
        uses: actions/download-artifact@v8.0.1
        with:
          name: xgboost-cpu-ppc64le-wheel
          path: wheelhouse
      - name: Run Python tests (CPU, ppc64le)
        run: bash ops/pipeline/test-python-wheel.sh --suite cpu-ppc64le
```

**Why `runs-on: ubuntu-24.04-ppc64le` directly here (not `fromJSON`)**

This job is not matrix-driven, so the runner is fixed. A plain string is sufficient — there
is no need for the `fromJSON` pattern used in `build-python-wheels-cpu`.

**Reason**

`test-python-wheel-cpu` depends on `audit-cuda-wheel` and tests CUDA wheels. The ppc64le
test job has a different artifact source (`build-python-wheels-cpu` → CPU wheel) and a
different conda environment (`ppc64le_test`), making a separate job the cleanest approach.

**Priority**: Required

---

## 6. Installation / Setup Changes

| Component | Current | ppc64le Required | Status |
|---|---|---|---|
| Miniforge installer | `Linux-aarch64.sh` | `Linux-ppc64le.sh` | Required — addressed in Change 2 |
| gcc-toolset-10 | Available in manylinux_2_28_aarch64 | Must verify in manylinux_2_28_ppc64le | Verify |
| gosu binary | amd64 / arm64 / i386 | Needs `ppc64le` binary + SHA-256 | Required — addressed in Change 1 |
| Conda environment | `aarch64_test.yml` | `ppc64le_test.yml` | Required — addressed in Change 3 |
| `auditwheel` | present in `aarch64_test` | must be present in `ppc64le_test` | Required — addressed in Change 3 |
| `/opt/python/cp312-cp312/bin/python` | present in all manylinux images | must verify in ppc64le image | Verify |

---

## 7. Architecture-Specific Logic

### `build-python-wheels-cpu.sh`

| Code | Analysis |
|---|---|
| `IMAGE_REPO="xgb-ci.${WHEEL_TAG}"` | **No Change** — `WHEEL_TAG` expands to `manylinux_2_28_ppc64le`; the new image resolves correctly. |
| `auditwheel repair --plat ${WHEEL_TAG}` | **No Change** — `${WHEEL_TAG}` = `manylinux_2_28_ppc64le`; auditwheel supports this tag. |
| `pydistcheck --config pyproject.toml` | **Verify** — confirm pydistcheck does not hard-code size limits that differ by arch. |
| `PYTHON_BIN="/opt/python/cp312-cp312/bin/python"` | **Verify** — this path must exist in `quay.io/pypa/manylinux_2_28_ppc64le`. |

### `test-python-wheel.sh`

| Code | Analysis |
|---|---|
| `source activate linux_cpu_test` | **Required** — use `ppc64le_test` env instead (Change 8). |
| Suite validation allow-list | **Required** — add `cpu-ppc64le` (Change 8). |
| PySpark tests | **Verify** — validate `pyspark>=4.0` conda-forge availability for `linux-ppc64le`. |

### `install_gosu.sh`

On ppc64le, `uname -m` returns `ppc64le`. The script currently fails for this value —
this is a **hard blocker** (Change 1).

---

## 8. Matrix Changes

### `build-python-wheels-cpu` — full before/after

```yaml
# ── BEFORE ────────────────────────────────────────────────────────────────────
  build-python-wheels-cpu:
    name: Build CPU wheel (xgboost-cpu) for ${{ matrix.manylinux_target }}_${{ matrix.arch }}
    runs-on:
      - runs-on
      - runner=${{ matrix.runner }}
      - run-id=${{ github.run_id }}
      - tag=main-build-python-wheels-cpu-${{ matrix.manylinux_target }}-${{ matrix.arch }}
    strategy:
      fail-fast: false
      matrix:
        include:
        - manylinux_target: manylinux_2_28
          arch: aarch64
          runner: linux-arm64-cpu
        - manylinux_target: manylinux_2_28
          arch: x86_64
          runner: linux-amd64-cpu

# ── AFTER ─────────────────────────────────────────────────────────────────────
  build-python-wheels-cpu:
    name: Build CPU wheel (xgboost-cpu) for ${{ matrix.manylinux_target }}_${{ matrix.arch }}
    runs-on: ${{ fromJSON(matrix.runs_on) }}
    strategy:
      fail-fast: false
      matrix:
        include:
        - manylinux_target: manylinux_2_28
          arch: aarch64
          runs_on: '["runs-on", "runner=linux-arm64-cpu", "run-id=${{ github.run_id }}", "tag=main-build-python-wheels-cpu-manylinux_2_28-aarch64"]'
        - manylinux_target: manylinux_2_28
          arch: x86_64
          runs_on: '["runs-on", "runner=linux-amd64-cpu", "run-id=${{ github.run_id }}", "tag=main-build-python-wheels-cpu-manylinux_2_28-x86_64"]'
        - manylinux_target: manylinux_2_28
          arch: ppc64le
          runs_on: '"ubuntu-24.04-ppc64le"'
```

**Matrix expansion impact**: Zero. This is an `include`-only matrix with no cross-product
dimensions. Adding one entry adds exactly one new job.

### `build-containers` matrix (xgboost-devops)

```yaml
include:
  # ... existing aarch64 entries ...
  - image_repo: xgb-ci.manylinux_2_28_ppc64le
    runner: linux-ppc64le-cpu
```

---

## 9. Cache and Artifact Considerations

- The `build-python-wheels-cpu` tag now encodes arch in the YAML string literal for x86_64
  and aarch64 entries, and uses `ubuntu-24.04-ppc64le` tag for ppc64le. No collision.
- The test job uses `actions/download-artifact` with the unique name
  `xgboost-cpu-ppc64le-wheel` — no collision with any existing artifact.
- The `RUNS_ON_S3_BUCKET_CACHE` environment variable is only available when running inside
  the runs-on SaaS service. On the ppc64le self-hosted runner it will be absent, which is
  why `actions/upload-artifact` is used instead of an S3 stash for Change 7.

---

## 10. Third-Party Action Considerations

| Action | Concern | Verdict |
|---|---|---|
| `actions/checkout@v7.0.1` | JavaScript action — architecture-neutral | No concern |
| `actions/upload-artifact@v7.0.1` | JavaScript action — architecture-neutral | No concern |
| `actions/download-artifact@v8.0.1` | JavaScript action — architecture-neutral | No concern |
| `aws-actions/amazon-ecr-login@v2.1.7` | Runs in `ci-configure` on amd64, not on ppc64le runner | No concern |
| `dmlc/xgboost-devops/actions/sccache@main` | Not used in `build-python-wheels-cpu`. If added to the ppc64le job, verify sccache binary availability for ppc64le. | Verify if added |
| `runs-on/action@v2` | Used only in GPU/CUDA jobs, not in the jobs being added | No concern |

---

## 11. External Dependencies / Blockers

| # | Dependency | Type | Detail |
|---|---|---|---|
| 1 | `quay.io/pypa/manylinux_2_28_ppc64le` | **Blocker** | Verify this image tag is published on quay.io/pypa. Without it the Dockerfile cannot be built. |
| 2 | `gosu 1.10 ppc64le` binary | **Blocker** | `install_gosu.sh` must be extended with a ppc64le case and the correct SHA-256 checksum. Verify `gosu-ppc64le` exists at [github.com/tianon/gosu/releases/tag/1.10](https://github.com/tianon/gosu/releases/tag/1.10). |
| 3 | `ubuntu-24.04-ppc64le` self-hosted runner | **Blocker** | A community-provided ppc64le runner must be registered in the target GitHub repository. Without it, all ppc64le jobs fail at scheduling time. |
| 4 | Miniforge ppc64le installer | **Blocker** | `Miniforge3-26.3.2-3-Linux-ppc64le.sh` must be available from conda-forge. Verify at [github.com/conda-forge/miniforge/releases](https://github.com/conda-forge/miniforge/releases). |
| 5 | conda-forge `linux-ppc64le` packages | **Verify** | All packages in `ppc64le_test.yml` must have `linux-ppc64le` builds. Packages to validate: `dask`, `distributed`, `pyspark>=4.0`, `pyarrow`, `hypothesis`, `loky>=3.5.1`. |
| 6 | `gcc-toolset-10` in ppc64le manylinux | **Verify** | The manylinux_2_28_ppc64le base image may bundle a different default GCC toolset. Inspect the image before pinning `gcc-toolset-10`. |
| 7 | `/opt/python/cp312-cp312/bin/python` path | **Verify** | All quay.io/pypa manylinux_2_28 images include pre-built CPython at this path. Confirm for ppc64le. |
| 8 | `RUNS_ON_S3_BUCKET_CACHE` not available | **By design** | This env var is injected by the runs-on SaaS service and will not be present on the self-hosted ppc64le runner. All wheel sharing between build and test uses `actions/upload-artifact` instead of S3. |

---

## 12. Change Summary

| File | Location | Change | Priority |
|---|---|---|---|
| `xgboost-devops/containers/scripts/install_gosu.sh` | `case "${arch}"` + checksum table | Add `ppc64le` arch + SHA-256 | Required (blocker) |
| `xgboost-devops/containers/dockerfile/Dockerfile.manylinux_2_28_ppc64le` | New file | Create ppc64le manylinux image | Required |
| `xgboost-devops/containers/conda_env/ppc64le_test.yml` | New file | Create ppc64le conda env | Required |
| `xgboost-devops/containers/ci_container.yml` | After `manylinux_2_28_aarch64` entry | Register `xgb-ci.manylinux_2_28_ppc64le` | Required |
| `xgboost-devops/.github/workflows/containers.yml` | `matrix.include` | Add `xgb-ci.manylinux_2_28_ppc64le` build entry | Required |
| `xgboost/.github/workflows/main.yml` | `build-python-wheels-cpu.runs-on` | Replace static list with `fromJSON(matrix.runs_on)` | Required |
| `xgboost/.github/workflows/main.yml` | `build-python-wheels-cpu.strategy.matrix.include` | Replace `runner:` fields with `runs_on:` JSON strings; add ppc64le entry | Required |
| `xgboost/.github/workflows/main.yml` | `build-python-wheels-cpu.steps` | Add `actions/upload-artifact` step for ppc64le wheel | Required |
| `xgboost/.github/workflows/main.yml` | After `test-python-wheel-cpu` | Add `test-python-wheel-cpu-ppc64le` job | Required |
| `xgboost/ops/pipeline/test-python-wheel.sh` | Suite validation, activation, and test blocks | Add `cpu-ppc64le` suite | Required |

---

## 13. Validation Plan

### Step 1 — Verify blockers before writing any YAML

```bash
# 1a. Confirm quay.io/pypa ppc64le manylinux image exists
docker pull quay.io/pypa/manylinux_2_28_ppc64le
docker run --rm quay.io/pypa/manylinux_2_28_ppc64le uname -m
# Expected: ppc64le

# 1b. Confirm gosu-ppc64le exists at version 1.10
curl -I https://github.com/tianon/gosu/releases/download/1.10/gosu-ppc64le
# Expected: HTTP 302 (redirect to release asset)

# 1c. Confirm Miniforge ppc64le installer exists
curl -I https://github.com/conda-forge/miniforge/releases/download/26.3.2-3/Miniforge3-26.3.2-3-Linux-ppc64le.sh
# Expected: HTTP 302

# 1d. Confirm /opt/python/cp312-cp312/bin/python inside the image
docker run --rm quay.io/pypa/manylinux_2_28_ppc64le ls /opt/python/cp312-cp312/bin/python
# Expected: file exists
```

### Step 2 — Build the container image

On a ppc64le host or using `docker buildx`:

```bash
cd xgboost-devops
BRANCH_NAME=PR-test GITHUB_SHA=$(git rev-parse HEAD) \
  bash containers/docker_build.sh xgb-ci.manylinux_2_28_ppc64le
```

Expected: image builds without errors.

### Step 3 — Verify wheel build (manual smoke test)

```bash
docker run --rm -v $(pwd):/workspace -w /workspace \
  xgb-ci.manylinux_2_28_ppc64le:main \
  bash -c "cd python-package && \
    /opt/python/cp312-cp312/bin/python -m pip wheel --no-deps -v . --wheel-dir dist/"
```

Expected: `xgboost_cpu-*.whl` produced in `python-package/dist/`.

### Step 4 — Verify auditwheel compliance

```bash
auditwheel repair --only-plat --plat manylinux_2_28_ppc64le \
  python-package/dist/xgboost_cpu-*.whl
```

Expected: repaired wheel in `wheelhouse/` containing `libgomp.so`.

### Step 5 — Validate architecture on the runner

Add a diagnostic step in the GitHub Actions workflow:

```yaml
- name: Verify architecture
  run: |
    uname -m
    python3 --version
    python3 -c "import platform; print(platform.machine())"
```

Expected output:
```
ppc64le
Python 3.12.x
ppc64le
```

### Step 6 — Dispatch the build job

Use `workflow_dispatch` on a test branch and confirm:

- ✅ ppc64le job picks up `ubuntu-24.04-ppc64le` runner (not runs-on SaaS)
- ✅ x86_64 and aarch64 jobs still pick up their runs-on SaaS runners (behaviour unchanged)
- ✅ Container pulls `xgb-ci.manylinux_2_28_ppc64le:main`
- ✅ `build-python-wheels-cpu.sh manylinux_2_28 ppc64le` completes
- ✅ Wheel tagged `manylinux_2_28_ppc64le` appears in `python-package/dist/`
- ✅ `libgomp.so` is vendored in the wheel
- ✅ Wheel uploaded via `actions/upload-artifact`

### Step 7 — Run the test job

Confirm:

- ✅ Wheel downloaded via `actions/download-artifact`
- ✅ `ppc64le_test` conda environment activates
- ✅ `pytest tests/python/test_basic.py tests/python/test_basic_models.py tests/python/test_model_compatibility.py` passes

---

## 14. Final Recommendation

Add ppc64le support using the **same `include`-entry pattern** that aarch64 uses today.
The one structural change that differs from aarch64 is the `runs-on` block: replace the
static SaaS label list with `runs-on: ${{ fromJSON(matrix.runs_on) }}` and encode each
entry's full runner specification as a JSON string in `runs_on`. This keeps x86_64 and
aarch64 behaviour identical to today while routing ppc64le to the community self-hosted
`ubuntu-24.04-ppc64le` runner — without any `if:` conditions or duplicate jobs.

Before touching any workflow YAML, resolve the three hard blockers in order:

1. Confirm `quay.io/pypa/manylinux_2_28_ppc64le` is published.
2. Add `ppc64le` to `install_gosu.sh` with the correct gosu SHA-256.
3. Register the `ubuntu-24.04-ppc64le` self-hosted runner in the target repository.

Once those are done, the `Dockerfile` → `ci_container.yml` → `containers.yml` → `main.yml`
chain can be implemented and landed as a single coordinated PR across `xgboost-devops`
(container changes) and `xgboost` (workflow + script changes).
