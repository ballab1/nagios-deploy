#!/bin/bash

# Use the Unofficial Bash Strict Mode
set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'
declare -r CBF_URL="https://github.com/ballab1/container_build_framework/archive"
export CBF_DIR_TEMP
export CHAIN_EXIT_HANDLER


function __init.die() {
    echo "$1" >&2
    exit 1
}

function __init.loader() {
#    __init.loadCBF

    # only load libraries from bashlib (not below). Sort to be deterministic
    local __libdir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    __libdir="$(readlink -f "${__libdir}/../bashlib")"
    local -a __libs
    mapfile -t __libs < <(find "$__libdir" -maxdepth 1 -mindepth 1 -name '*.bashlib' | sort)
    if [ "${#__libs[*]}" -eq 0 ] && [ -d /usr/local/crf/bashlib ]; then
        mapfile -t __libs < <(find /usr/local/crf/bashlib -maxdepth 1 -mindepth 1 -name '*.bashlib' | sort)
    fi

    if [ "${#__libs[*]}" -gt 0 ]; then
        echo -en "    loading project libraries from $__libdir: \e[35m"
        [[ "${DEBUG:-}" || "${DEBUG_TRACE:-0}" -gt 0 ]] && echo
        for __lib in "${__libs[@]}"; do
            if [[ "${DEBUG:-}" || "${DEBUG_TRACE:-0}" -gt 0 ]]; then
                echo "        $__lib"
            else
                echo -n " $(basename "$__lib")"
            fi
            source "$__lib"
        done
        echo -e '\e[0m'
    fi
    [ ! -e "${__libdir}/init.cache" ] || source "${__libdir}/init.cache"
}

function __init.loadCBF() {
    local cbf_dir="${CONTAINER_DIR:-}"
    : ${__cbfVersion:=master}
    [ -z "${CBF_VERSION:-}" ] || __cbfVersion=$CBF_VERSION

    # check if we need to download CBF
    if [ "${cbf_dir:-}" ] && [ -d "$cbf_dir" ]; then
        echo "Using local build version of CBF"

    elif [ "${TOP:-}" ] && [ -d "${TOP}/container_build_framework" ] ; then
        echo "Using CBF submodule"
        cbf_dir="${TOP}/container_build_framework"

    elif [ "${__cbfVersion:-}" ]; then
        __init.myExitHandler
        local CBF_DIR_TEMP=$(mktemp -d)
        cbf_dir="${CBF_DIR_TEMP}/container_build_framework"

        # since no CBF directory located, attempt to download CBF based on specified verion
        local cbf_tgz="${CBF_DIR_TEMP}/cbf.tar.gz"
        local cbf_url="${CBF_URL}/${__cbfVersion}.tar.gz"
        echo "Downloading CBF:$__cbfVersion from $cbf_url"

        wget --no-check-certificate --quiet --output-document="$cbf_tgz" "$cbf_url" || __init.die "Failed to download $cbf_url"
        if type -f wget &> /dev/null ; then
            wget --no-check-certificate --quiet --output-document="$cbf_tgz" "$cbf_url" || __init.die "Failed to download $cbf_url"
        elif type -f curl &> /dev/null ; then
            curl --insecure --silent --output "$cbf_tgz" "$cbf_url" || __init.die "Failed to download $cbf_url"
        else
            __init.die "Neither wget or curl is installed to download cbf from $cbf_url"
        fi

        echo 'Unpacking downloaded copy of CBF'
        tar -xzf "$cbf_tgz" -C "$CBF_DIR_TEMP" || __init.die "Failed to unpack $cbf_tgz"
        cbf_dir="$( ls -d "${CBF_DIR_TEMP}/container_build_framework"* 2>/dev/null )"
    fi
    unset __cbfVersion


    # verify CBF directory exists
    [ "$cbf_dir" ] && [ -d "$cbf_dir" ] ||  __init.die 'No framework directory located'


    echo "loading framework from ${cbf_dir}"

    # load our CBF libraries
    [ ! -e "${cbf_dir}/bashlibs.loaded" ] || rm "${cbf_dir}/bashlibs.loaded" ||  __init.die "Failed to remove ${cbf_dir}/bashlibs.loaded"

    export CBF_LOCATION="$cbf_dir"                   # set CBF_LOCATION
    export CRF_LOCATION="$CBF_LOCATION/cbf"          # set CRF_LOCATION
    export CONTAINER_NAME=xxx                        # dummy name while initialization in progress
    # shellcheck source=../container_build_framework/cbf/bin/init.libraries
    source "$( readlink -f "${cbf_dir}/cbf/bin" )/init.libraries"
}

function __init.myExitHandler() {
    __init.rmTmpDir() {
        local -i status=$?
        [ -z "${CBF_DIR_TEMP:-}" ] || [ ! -d "$CBF_DIR_TEMP" ] || rm -rf "$CBF_DIR_TEMP"
        [ -z "${CHAIN_EXIT_HANDLER:-}" ] || "$CHAIN_EXIT_HANDLER"
        exit $status
    }
    CHAIN_EXIT_HANDLER=$(trap -p EXIT | awk '{print $3}' | tr -d "'")
    trap __init.rmTmpDir EXIT
}

if [[ "${DEBUG:-}" || "${DEBUG_TRACE:-0}" -gt 0 ]]; then
    __init.loader >&2
else
    __init.loader &> /dev/null
fi
