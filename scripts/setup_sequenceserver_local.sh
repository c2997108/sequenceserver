#!/usr/bin/env bash
#
# setup_sequenceserver_local.sh
# ---------------------------------
# Build a fully self-contained SequenceServer runtime under this repository
# without touching any system-level directories.
# Steps performed:
#   1. Download and compile OpenSSL (default 1.1.1w) into vendor/
#   2. Download and compile Ruby (default 3.0.7) linked against that OpenSSL
#   3. Install Bundler (default 2.5.17) using the private Ruby
#   4. Install SequenceServer gem dependencies into vendor/bundle
#   5. Generate bin/seqserv-wrapper and seqserv.service templates
#
# All artefacts remain beneath the repository root so the folder can be moved
# or archived without additional steps.

set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/vendor"
DEFAULT_DB_DIR="${ROOT_DIR}/data/blastdb"

if [[ ! -f "${ROOT_DIR}/Gemfile" ]]; then
  echo "error: Gemfile not found at ${ROOT_DIR}/Gemfile. Run this script from the cloned SequenceServer repo." >&2
  exit 1
fi

OPENSSL_VERSION="${OPENSSL_VERSION:-1.1.1w}"
OPENSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_SRC="${VENDOR_DIR}/openssl-${OPENSSL_VERSION}"
OPENSSL_PREFIX="${VENDOR_DIR}/openssl-${OPENSSL_VERSION}-local"
OPENSSL_URL="https://www.openssl.org/source/${OPENSSL_TARBALL}"

RUBY_VERSION="${RUBY_VERSION:-3.0.7}"
RUBY_TARBALL="ruby-${RUBY_VERSION}.tar.gz"
RUBY_SRC="${VENDOR_DIR}/ruby-${RUBY_VERSION}"
RUBY_PREFIX="${VENDOR_DIR}/ruby-${RUBY_VERSION}-withssl"
RUBY_URL="https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/${RUBY_TARBALL}"

BUNDLER_VERSION="${BUNDLER_VERSION:-2.5.17}"

RUBY_DIR_NAME="$(basename "${RUBY_PREFIX}")"
RUBY_REL_DIR="vendor/${RUBY_DIR_NAME}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command '$1' not found in PATH" >&2
    exit 1
  fi
}

msg() {
  echo "-- $*"
}

need_cmd curl
need_cmd tar
need_cmd make
need_cmd gcc
need_cmd perl

mkdir -p "${VENDOR_DIR}"
mkdir -p "${DEFAULT_DB_DIR}"
msg "Using default BLAST DB directory: ${DEFAULT_DB_DIR}"

# --- OpenSSL -----------------------------------------------------------------
if [[ ! -d "${OPENSSL_PREFIX}" ]]; then
  msg "Building OpenSSL ${OPENSSL_VERSION}"
  if [[ ! -f "${VENDOR_DIR}/${OPENSSL_TARBALL}" ]]; then
    msg "  downloading ${OPENSSL_URL}"
    curl -fsSL "${OPENSSL_URL}" -o "${VENDOR_DIR}/${OPENSSL_TARBALL}"
  fi
  rm -rf "${OPENSSL_SRC}"
  tar -xf "${VENDOR_DIR}/${OPENSSL_TARBALL}" -C "${VENDOR_DIR}"
  pushd "${OPENSSL_SRC}" >/dev/null
  ./config --prefix="${OPENSSL_PREFIX}" --openssldir="${OPENSSL_PREFIX}/ssl"
  make -j"$(nproc)"
  make install_sw
  popd >/dev/null
else
  msg "Reusing existing OpenSSL at ${OPENSSL_PREFIX}"
fi

# --- Ruby --------------------------------------------------------------------
if [[ ! -x "${RUBY_PREFIX}/bin/ruby" ]]; then
  msg "Building Ruby ${RUBY_VERSION}"
  if [[ ! -f "${VENDOR_DIR}/${RUBY_TARBALL}" ]]; then
    msg "  downloading ${RUBY_URL}"
    curl -fsSL "${RUBY_URL}" -o "${VENDOR_DIR}/${RUBY_TARBALL}"
  fi
  rm -rf "${RUBY_SRC}"
  tar -xf "${VENDOR_DIR}/${RUBY_TARBALL}" -C "${VENDOR_DIR}"
  pushd "${RUBY_SRC}" >/dev/null
  ./configure --prefix="${RUBY_PREFIX}" --disable-install-doc --with-openssl-dir="${OPENSSL_PREFIX}"
  make -j"$(nproc)"
  make install
  popd >/dev/null
else
  msg "Reusing existing Ruby at ${RUBY_PREFIX}"
fi

export PATH="${RUBY_PREFIX}/bin:${PATH}"
export GEM_HOME="${RUBY_PREFIX}/lib/ruby/gems/3.0.0"
export GEM_PATH="${GEM_HOME}"
export BUNDLE_GEMFILE="${ROOT_DIR}/Gemfile"
export BUNDLE_PATH="${ROOT_DIR}/vendor/bundle"
export BUNDLE_WITHOUT="${BUNDLE_WITHOUT:-development:test}"

# --- Bundler -----------------------------------------------------------------
if ! gem list -i bundler -v "${BUNDLER_VERSION}" >/dev/null 2>&1; then
  msg "Installing Bundler ${BUNDLER_VERSION}"
  gem install bundler -v "${BUNDLER_VERSION}" --no-document
else
  msg "Bundler ${BUNDLER_VERSION} already installed"
fi

# --- Bundler configuration ---------------------------------------------------
msg "Writing Bundler config"
mkdir -p "${ROOT_DIR}/.bundle"
cat > "${ROOT_DIR}/.bundle/config" <<'EOF'
---
BUNDLE_PATH: "vendor/bundle"
BUNDLE_WITHOUT: "development:test"
EOF

# --- SequenceServer gems -----------------------------------------------------
msg "Installing SequenceServer gems"
bundle _"${BUNDLER_VERSION}"_ install --jobs "$(nproc)" --retry 3

# --- Wrapper script ----------------------------------------------------------
WRAPPER="${ROOT_DIR}/bin/seqserv-wrapper"
msg "Writing wrapper script ${WRAPPER}"
cat > "${WRAPPER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFS=\$'\n\t'

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="\$(cd "\${SCRIPT_DIR}/.." && pwd)"

export PATH="\${APP_ROOT}/${RUBY_REL_DIR}/bin:\${PATH}"
export GEM_HOME="\${APP_ROOT}/${RUBY_REL_DIR}/lib/ruby/gems/3.0.0"
export GEM_PATH="\${GEM_HOME}"
export BUNDLE_GEMFILE="\${APP_ROOT}/Gemfile"
export BUNDLE_PATH="\${APP_ROOT}/vendor/bundle"
export BUNDLE_WITHOUT="\${BUNDLE_WITHOUT:-development:test}"

DEFAULT_DB_DIR="\${APP_ROOT}/data/blastdb"
DB_DIR="\${SEQSERVER_DB_DIR:-\${DEFAULT_DB_DIR}}"

db_arg_present=0
for arg in "\$@"; do
  case "\$arg" in
    --database_dir|-d|--database_dir=*|-d=*)
      db_arg_present=1
      break
      ;;
  esac
done

if [[ \${db_arg_present} -eq 0 ]]; then
  mkdir -p "\${DB_DIR}"
  set -- "\$@" --database_dir "\${DB_DIR}"
fi

cd "\${APP_ROOT}"
exec bundle _${BUNDLER_VERSION}_ exec bin/sequenceserver "\$@"
EOF
chmod +x "${WRAPPER}"

# --- systemd unit template ---------------------------------------------------
SERVICE_UNIT="${ROOT_DIR}/seqserv.service"
msg "Writing systemd unit template to ${SERVICE_UNIT}"
cat > "${SERVICE_UNIT}" <<EOF
[Unit]
Description=SequenceServer BLAST web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=seqserv
Group=seqserv
WorkingDirectory=${ROOT_DIR}
Environment=SEQSERVER_DB_DIR=${DEFAULT_DB_DIR}
ExecStart=${WRAPPER} --host 0.0.0.0 --port 4567
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

msg "Setup complete."
msg "Launch manually with: ${WRAPPER} --host 0.0.0.0 --port 4567"
msg "To install as a service, adjust ${SERVICE_UNIT} and copy it under /etc/systemd/system/."
