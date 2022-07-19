#!/bin/bash
# Originally derived from gitlab common.sh


# Checks that appropriate gke params are set and
# that gcloud and kubectl are properly installed and authenticated
function need_tool(){
  local tool="${1}"
  local url="${2}"

  echo >&2 "${tool} is required. Please follow ${url}"
  exit 1
}

function need_kubectl(){
  need_tool "kubectl" "https://kubernetes.io/docs/tasks/tools/install-kubectl"
}

function need_helm(){
  need_tool "helm" "https://github.com/helm/helm/#install"
}

function need_az(){
  need_tool "az" "https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
}

function need_jq(){
  need_tool "jq" "https://stedolan.github.io/jq/download/"
}

function need_dotenv(){
  need_tool "dotenv" "https://pypi.org/project/python-dotenv/"
}

function validate_tools(){
  for tool in "$@"
  do
    # Basic check for installation
    command -v "${tool}" > /dev/null 2>&1 || "need_${tool}"

    # Additional check if validating Helm
    if [ "$tool" == 'helm' ]; then
      if ! helm version --short --client | grep -q '^v3\.[0-9]\{1,\}'; then
        echo "Helm 3+ is required.";
        exit 1
      fi
    fi
  done
}

# Function to compare versions in a semver compatible way
# given args A and B, return 0 if A=B, -1 if A<B and 1 if A>B
function semver_compare() {
  if [ "$1" = "$2" ]; then
    # A = B
    echo 0
  else
    ordered=$(printf '%s\n' "$@" | sort -V | head -n 1)

    if [ "$ordered" = "$1" ]; then
      # A < B
      echo -1
    else
      # A > B
      echo 1
    fi
  fi
}

# Check to see if this file is being run or sourced from another script
function is_sourced() {
  # See also https://unix.stackexchange.com/a/215279
  # macos bash source check OR { linux shell check }
  [[ "${#BASH_SOURCE[@]}" -eq 0 ]] || { [ "${#FUNCNAME[@]}" -ge 2 ]  && [ "${FUNCNAME[0]}" = '_is_sourced' ] && [ "${FUNCNAME[1]}" = 'source' ]; }
}

# Write the message to stderr.
# https://stackoverflow.com/a/2990533/176882
function echoerr() { printf "%s\n" "$*" >&2; }
