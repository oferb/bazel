#!/bin/bash

# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu

# Main deploy functions for the continous build system
# Just source this file and use the various method:
#   bazel_build build bazel and run all its test
#   bazel_release use the artifact generated by bazel_build and push
#     them to github for a release and to GCS for a release candidate.
#     Also prepare an email for announcing the release.

# Load common.sh
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source $(dirname ${SCRIPT_DIR})/release/common.sh

: ${GIT_REPOSITORY_URL:=https://github.com/bazelbuild/bazel}

: ${GCS_BASE_URL:=https://storage.googleapis.com}
: ${GCS_BUCKET:=bucket-o-bazel}
: ${GCS_APT_BUCKET:=bazel-apt}

: ${EMAIL_TEMPLATE_RC:=${SCRIPT_DIR}/rc_email.txt}
: ${EMAIL_TEMPLATE_RELEASE:=${SCRIPT_DIR}/release_email.txt}

: ${RELEASE_CANDIDATE_URL:="https://releases.bazel.build/%release_name%/rc%rc%/index.html"}
: ${RELEASE_URL="${GIT_REPOSITORY_URL}/releases/tag/%release_name%"}

: ${BOOTSTRAP_BAZEL:=bazel}

# Generate a string from a template and a list of substitutions.
# The first parameter is the template name and each subsequent parameter
# is taken as a couple: first is the string the substitute and the second
# is the result of the substitution.
function generate_from_template() {
  local value="$1"
  shift
  while (( $# >= 2 )); do
    value="${value//$1/$2}"
    shift 2
  done
  echo "${value}"
}

# Generate the email for the release.
# The first line of the output will be the recipient, the second line
# the mail subjects and the subsequent lines the mail, its content.
# If no planed release, then this function output will be empty.
function generate_email() {
  local release_name=$(get_release_name)
  local rc=$(get_release_candidate)
  local args=(
      "%release_name%" "${release_name}"
      "%rc%" "${rc}"
      "%relnotes%" "# $(get_full_release_notes)"
  )
  if [ -n "${rc}" ]; then
    args+=(
        "%url%"
        "$(generate_from_template "${RELEASE_CANDIDATE_URL}" "${args[@]}")"
    )
    generate_from_template "$(cat ${EMAIL_TEMPLATE_RC})" "${args[@]}"
  elif [ -n "${release_name}" ]; then
    args+=(
        "%url%"
        "$(generate_from_template "${RELEASE_URL}" "${args[@]}")"
    )
    generate_from_template "$(cat ${EMAIL_TEMPLATE_RELEASE})" "${args[@]}"
  fi
}

function get_release_page() {
    echo "# $(get_full_release_notes)"'

_Notice_: Bazel installers contain binaries licensed under the GPLv2 with
Classpath exception. Those installers should always be redistributed along with
the source code.

Some versions of Bazel contain a bundled version of OpenJDK. The license of the
bundled OpenJDK and other open-source components can be displayed by running
the command `bazel license`. The vendor and version information of the bundled
OpenJDK can be displayed by running the command `bazel info java-runtime`.
The binaries and source-code of the bundled OpenJDK can be
[downloaded from our mirror server](https://mirror.bazel.build/openjdk/index.html).

_Security_: All our binaries are signed with our
[public key](https://bazel.build/bazel-release.pub.gpg) 48457EE0.
'
}

# Deploy a github release using a third party tool:
#   https://github.com/c4milo/github-release
# This methods expects the following arguments:
#   $1..$n files generated by package_build (should not contains the README file)
# Please set GITHUB_TOKEN to talk to the Github API and GITHUB_RELEASE
# for the path to the https://github.com/c4milo/github-release tool.
# This method is also affected by GIT_REPOSITORY_URL which should be the
# URL to the github repository (defaulted to https://github.com/bazelbuild/bazel).
function release_to_github() {
  local url="${GIT_REPOSITORY_URL}"
  local release_name=$(get_release_name)
  local rc=$(get_release_candidate)
  local release_tool="${GITHUB_RELEASE:-$(which github-release 2>/dev/null || echo release-tool-not-found)}"

  if [ "${release_tool}" = "release-tool-not-found" ]; then
    echo "Please set GITHUB_RELEASE to the path to the github-release binary." >&2
    echo "This probably means you haven't installed https://github.com/c4milo/github-release " >&2
    echo "on this machine." >&2
    return 1
  fi
  local github_repo="$(echo "$url" | sed -E 's|https?://github.com/([^/]*/[^/]*).*$|\1|')"
  if [ -n "${release_name}" ] && [ -z "${rc}" ]; then
    mkdir -p "${tmpdir}/to-github"
    cp "${@}" "${tmpdir}/to-github"
    "${release_tool}" "${github_repo}" "${release_name}" "" "$(get_release_page)" "${tmpdir}/to-github/"'*'
  fi
}

# Creates an index of the files contained in folder $1 in mardown format
function create_index_md() {
  # First, add the release notes
  get_release_page
  # Build log
  if [ -f $1/build.log ]; then
    echo
    echo " [Build log](build.log)"
    echo
  fi
  # Then, add the list of files
  echo
  echo "## Index of files"
  echo
  for f in $1/*.sha256; do  # just list the sha256 ones
    local filename=$(basename $f .sha256);
    echo " - [${filename}](${filename}) [[SHA-256](${filename}.sha256)] [[SIG](${filename}.sig)]"
  done
}

# Creates an index of the files contained in folder $1 in HTML format
# It supposes hoedown (https://github.com/hoedown/hoedown) is on the path,
# if not, set the HOEDOWN environment variable to the good path.
function create_index_html() {
  local hoedown="${HOEDOWN:-$(which hoedown 2>/dev/null || true)}"
  # Second line is to trick hoedown to behave as Github
  create_index_md "${@}" \
      | sed -E 's/^(Baseline.*)$/\1\
/' | sed 's/^   + / - /' | sed 's/_/\\_/g' \
      | "${hoedown}"
}

function get_gsutil() {
  local gs="${GSUTIL:-$(which gsutil 2>/dev/null || true) -m}"
  if [ ! -x "${gs}" ]; then
    echo "Please set GSUTIL to the path the gsutil binary." >&2
    echo "gsutil (https://cloud.google.com/storage/docs/gsutil/) is the" >&2
    echo "command-line interface to google cloud." >&2
    exit 1
  fi
  echo "${gs}"
}

# Deploy a release candidate to Google Cloud Storage.
# It requires to have gsutil installed. You can force the path to gsutil
# by setting the GSUTIL environment variable. The GCS_BUCKET should be the
# name of the Google cloud bucket to deploy to.
# This methods expects the following arguments:
#   $1..$n files generated by package_build
function release_to_gcs() {
  local gs="$(get_gsutil)"
  local release_name="$(get_release_name)"
  local rc="$(get_release_candidate)"
  if [ -z "${GCS_BUCKET-}" ]; then
    echo "Please set GCS_BUCKET to the name of your Google Cloud Storage bucket." >&2
    return 1
  fi
  if [ -n "${release_name}" ]; then
    local release_path="${release_name}/release"
    if [ -n "${rc}" ]; then
      release_path="${release_name}/rc${rc}"
    fi
    # Make a temporary folder with the desired structure
    local dir="$(mktemp -d ${TMPDIR:-/tmp}/tmp.XXXXXXXX)"
    local prev_dir="$PWD"
    trap "{ cd ${prev_dir}; rm -fr ${dir}; }" EXIT
    mkdir -p "${dir}/${release_path}"
    cp "${@}" "${dir}/${release_path}"
    # Add a index.html file:
    create_index_html "${dir}/${release_path}" \
        >"${dir}/${release_path}"/index.html
    cd ${dir}
    "${gs}" -m cp -a public-read -r . "gs://${GCS_BUCKET}"
    cd "${prev_dir}"
    rm -fr "${dir}"
    trap - EXIT
  fi
}

function ensure_gpg_secret_key_imported() {
  (gpg --list-secret-keys | grep "${APT_GPG_KEY_ID}" > /dev/null) || \
  gpg --allow-secret-key-import --import "${APT_GPG_KEY_PATH}"
  # Make sure we use stronger digest algorithm。
  # We use reprepro to generate the debian repository,
  # but there's no way to pass flags to gpg using reprepro, so writting it into
  # ~/.gnupg/gpg.conf
  (grep "digest-algo sha256" ~/.gnupg/gpg.conf > /dev/null) || \
  echo "digest-algo sha256" >> ~/.gnupg/gpg.conf
}

function create_apt_repository() {
  mkdir conf
  cat > conf/distributions <<EOF
Origin: Bazel Authors
Label: Bazel
Codename: stable
Architectures: amd64 source
Components: jdk1.8
Description: Bazel APT Repository
DebOverride: override.stable
DscOverride: override.stable
SignWith: ${APT_GPG_KEY_ID}

Origin: Bazel Authors
Label: Bazel
Codename: testing
Architectures: amd64 source
Components: jdk1.8
Description: Bazel APT Repository
DebOverride: override.testing
DscOverride: override.testing
SignWith: ${APT_GPG_KEY_ID}
EOF

  cat > conf/options <<EOF
verbose
ask-passphrase
basedir .
EOF

  # TODO(#2264): this is a quick workaround #2256, figure out a correct fix.
  cat > conf/override.stable <<EOF
bazel     Section     contrib/devel
bazel     Priority    optional
EOF
  cat > conf/override.testing <<EOF
bazel     Section     contrib/devel
bazel     Priority    optional
EOF

  ensure_gpg_secret_key_imported

  local distribution="$1"
  local deb_pkg_name_jdk8="$2"
  local deb_dsc_name="$3"

  debsign -k ${APT_GPG_KEY_ID} "${deb_dsc_name}"

  reprepro -C jdk1.8 includedeb "${distribution}" "${deb_pkg_name_jdk8}"
  reprepro -C jdk1.8 includedsc "${distribution}" "${deb_dsc_name}"

  "${gs}" -m cp -a public-read -r dists "gs://${GCS_APT_BUCKET}/"
  "${gs}" -m cp -a public-read -r pool "gs://${GCS_APT_BUCKET}/"
}

function release_to_apt() {
  local gs="$(get_gsutil)"
  local release_name="$(get_release_name)"
  local rc="$(get_release_candidate)"
  if [ -z "${GCS_APT_BUCKET-}" ]; then
    echo "Please set GCS_APT_BUCKET to the name of your GCS bucket for apt repository." >&2
    return 1
  fi
  if [ -z "${APT_GPG_KEY_ID-}" ]; then
    echo "Please set APT_GPG_KEY_ID for apt repository." >&2
    return 1
  fi
  if [ -n "${release_name}" ]; then
    # Make a temporary folder with the desired structure
    local dir="$(mktemp -d ${TMPDIR:-/tmp}/tmp.XXXXXXXX)"
    local prev_dir="$PWD"
    trap "{ cd ${prev_dir}; rm -fr ${dir}; }" EXIT
    mkdir -p "${dir}/${release_name}"
    local release_label="$(get_full_release_name)"
    local deb_pkg_name_jdk8="${release_name}/bazel_${release_label}-linux-x86_64.deb"
    local deb_dsc_name="${release_name}/bazel_${release_label}.dsc"
    local deb_tar_name="${release_name}/bazel_${release_label}.tar.gz"
    cp "${tmpdir}/bazel_${release_label}-linux-x86_64.deb" "${dir}/${deb_pkg_name_jdk8}"
    cp "${tmpdir}/bazel.dsc" "${dir}/${deb_dsc_name}"
    cp "${tmpdir}/bazel.tar.gz" "${dir}/${deb_tar_name}"
    cd "${dir}"
    if [ -n "${rc}" ]; then
      create_apt_repository testing "${deb_pkg_name_jdk8}" "${deb_dsc_name}"
    else
      create_apt_repository stable "${deb_pkg_name_jdk8}" "${deb_dsc_name}"
    fi
    cd "${prev_dir}"
    rm -fr "${dir}"
    trap - EXIT
  fi
}

# A wrapper around the release deployment methods.
function deploy_release() {
  local github_args=()
  for i in "$@"; do
    if ! ( [[ "$i" =~ build.log ]] || [[ "$i" =~ bazel.dsc ]] || [[ "$i" =~ bazel.tar.gz ]] || [[ "$i" =~ .nobuild$ ]] ) ; then
      github_args+=("$i")
    fi
  done
  local gcs_args=()
  # Filters out perf.bazel.*.nobuild
  for i in "$@"; do
    if ! [[ "$i" =~ .nobuild$ ]] ; then
      gcs_args+=("$i")
    fi
  done
  release_to_github "${github_args[@]}"
  release_to_gcs "${gcs_args[@]}"
  release_to_apt
}
