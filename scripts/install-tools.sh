#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin_dir="$repo_root/.tools/bin"
versions_file="$repo_root/tools/versions.env"
checksums_file="$repo_root/tools/checksums.sha256"
temp_dir=""

cleanup() {
  if [[ -n "$temp_dir" ]]; then
    rm -rf "$temp_dir"
  fi
}
trap cleanup EXIT

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 1
  fi
}

download() {
  local url="$1"
  local filename="$2"

  curl --fail --location --retry 3 --silent --show-error --output "$temp_dir/$filename" "$url"
}

verify_checksum() {
  local filename="$1"

  if ! grep --fixed-strings --quiet "  $filename" "$checksums_file"; then
    echo "No publisher checksum inventory entry for $filename; continuing without checksum verification." >&2
    return
  fi

  (
    cd "$temp_dir"
    grep --fixed-strings "  $filename" "$checksums_file" | sha256sum --check --status -
  )
}

install_file() {
  local source_file="$1"
  local destination="$2"

  install -m 0755 "$source_file" "$bin_dir/$destination"
  if [[ ! -x "$bin_dir/$destination" ]]; then
    echo "Installed binary is missing or not executable: $destination" >&2
    exit 1
  fi
}

print_version() {
  local tool="$1"

  case "$tool" in
    kubectl)
      "$bin_dir/$tool" version --client=true --output=yaml | head -n 1
      ;;
    kubeconform)
      "$bin_dir/$tool" -v
      ;;
    *)
      "$bin_dir/$tool" version 2>/dev/null || "$bin_dir/$tool" --version
      ;;
  esac
}

for command_name in curl tar unzip sha256sum install; do
  require_command "$command_name"
done

if [[ ! -f "$versions_file" || ! -f "$checksums_file" ]]; then
  echo "Required tool metadata is missing under tools/." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$versions_file"

platform="$(uname -s)-$(uname -m)"
case "$platform" in
  Linux-x86_64 | Linux-amd64)
    terraform_archive="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    kubectl_artifact="kubectl"
    kustomize_archive="kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
    kubeconform_archive="kubeconform-linux-amd64.tar.gz"
    jq_artifact="jq-linux-amd64"
    shellcheck_archive="shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
    actionlint_archive="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
    crane_archive="go-containerregistry_Linux_x86_64.tar.gz"
    ;;
  *)
    echo "Unsupported platform: $platform. Supported platform: Linux x86_64." >&2
    exit 1
    ;;
esac

mkdir -p "$bin_dir"
temp_dir="$(mktemp -d)"

download "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${terraform_archive}" "$terraform_archive"
verify_checksum "$terraform_archive"
unzip -q "$temp_dir/$terraform_archive" -d "$temp_dir/terraform"
install_file "$temp_dir/terraform/terraform" terraform

download "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "$kubectl_artifact"
verify_checksum "$kubectl_artifact"
install_file "$temp_dir/$kubectl_artifact" kubectl

download "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v${KUSTOMIZE_VERSION}/${kustomize_archive}" "$kustomize_archive"
verify_checksum "$kustomize_archive"
tar -xzf "$temp_dir/$kustomize_archive" -C "$temp_dir"
install_file "$temp_dir/kustomize" kustomize

download "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/${kubeconform_archive}" "$kubeconform_archive"
verify_checksum "$kubeconform_archive"
mkdir -p "$temp_dir/kubeconform"
tar -xzf "$temp_dir/$kubeconform_archive" -C "$temp_dir/kubeconform"
install_file "$temp_dir/kubeconform/kubeconform" kubeconform

download "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${jq_artifact}" "$jq_artifact"
verify_checksum "$jq_artifact"
install_file "$temp_dir/$jq_artifact" jq

download "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${shellcheck_archive}" "$shellcheck_archive"
verify_checksum "$shellcheck_archive"
mkdir -p "$temp_dir/shellcheck"
tar -xJf "$temp_dir/$shellcheck_archive" -C "$temp_dir/shellcheck"
install_file "$temp_dir/shellcheck/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" shellcheck

download "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${actionlint_archive}" "$actionlint_archive"
verify_checksum "$actionlint_archive"
mkdir -p "$temp_dir/actionlint"
tar -xzf "$temp_dir/$actionlint_archive" -C "$temp_dir/actionlint"
install_file "$temp_dir/actionlint/actionlint" actionlint

download "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/${crane_archive}" "$crane_archive"
verify_checksum "$crane_archive"
mkdir -p "$temp_dir/crane"
tar -xzf "$temp_dir/$crane_archive" -C "$temp_dir/crane"
install_file "$temp_dir/crane/crane" crane

for tool in terraform kubectl kustomize kubeconform jq shellcheck actionlint crane; do
  if [[ ! -x "$bin_dir/$tool" ]]; then
    echo "Required installed binary is missing: $tool" >&2
    exit 1
  fi
  print_version "$tool"
done
