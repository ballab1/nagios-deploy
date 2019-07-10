#!/bin/bash

#----------------------------------------------------------------------------------------------
function build.usage()
{
    local -i exit_status=${1:-1}

    cat >&2 << EOF
Usage:
    $progname [ -h | --help ]
              [ -f | --force ]
              [ -c | --console ]
              [ --logdir <logDir> ]
              [ -l | --logfile <logName> ]
              [ -o | --os <osName> ]
              [ -p | --push ]
              [ <repoName> <repoName> <repoName> ]

    Common options:
        -h --help                  Display a basic set of usage instructions
        -c --console               log build info to conolse : default is to log to logdir and just display summary on cpnsole
        -f --force                 force build : do not check if fingerprint exists locally or in registry
           --logdir                log directory. If not specified, defalts to
        -l --logfile <logName>     log build results to <logName>. Defaults to build.YYYYMMDDhhmmss.log
        -o --os <osName>           specify OS <osName> that will be used. Default all OS types defined
        -p --push                  always push image to regitry

    build one or more component repos

EOF
    exit "$exit_status"
}

export PROGRESS_LOG

#----------------------------------------------------------------------------------------------
function build.all()
{
    local -r top="${1:?}"
    local -r logDir="${2:?}"
    shift 2
    local -ra userInput=( "$@" )

    local -r allStartTime=$(timer.getTimestamp)
    cd "$top"
    [ -d "$logDir" ] || mkdir -p "$logDir"


    VERSIONS_DIRECTORY="${top}/versions"
    local -a files=()
    mapfile -t files < <(ls -1 "$VERSIONS_DIRECTORY" | grep -vF '.' ||:)
    [ "${#files[*]}" -eq 0 ] && trap.die "No version information available."


    local updateTo
    [[ "$(git.branch)" = *dev* ]] && updateTo=latest
    [ "${CONTAINER_TAG:-}" ] && updateTo=latest

    local -a OSes
    mapfile -t OSes < <(sed '/^[[:blank:]]*#/d;s/[[:blank:]]*#.*//' container.os)
    [ "${CONTAINER_OS:-}" ] && OSes=( $CONTAINER_OS )

    local cbf_version="${CBF_VERSION:-}"
    if [ -z "${CBF_VERSION:-}" ]; then
        if [ -d "${top}/container_build_framework" ]; then
            cbf_version="$(build.cbfVersion)" || trap.die "Unable to save CBF to $(custom.storage)."'\n'
        else
            cbf_version='master'
        fi
    fi

    echo "Container Build Framework version: $cbf_version"
    echo "kafka servers:  ${KAFKA_BOOTSTRAP_SERVERS:-}"
    echo
    echo

    local -i status=0
    local request_cbf="${CBF_VERSION:-}"
    for containerOS in "${OSes[@]}"; do
        [ ${containerOS:-} ] || continue
        [ -e "$VERSIONS_DIRECTORY/$containerOS" ] || continue
        [ "${request_cbf:-}" ] || CBF_VERSION="$cbf_version"

        # run in separate shell to avoid "VERSIONS" conflicting
        (build.containersForOS "$containerOS" "${userInput[@]:-}") && status=$? || status=$?
        [ "$status" -ne 0 ] && break
    done


    echo
    echo
    TZ='America/New_York' date
    local allEndTime=$(timer.getTimestamp)
    local -i allElapsed=$(( allEndTime - allStartTime ))
    local allDuration="$(timer.fmtElapsed $allElapsed)"
    printf 'Time elapsed for overall build: %s\n' "$allDuration"

    build.logToKafka "$(date +%Y%m%d-%H%M%S.%N -u)" \
                     'n/a' \
                     "$(git.HEAD)" \
                     "$(git.remoteUrl)" \
                     "$(git.origin)" \
                     "$allDuration" \
                     "$allElapsed" \
                     "$(git.refs)" \
                     'overall build'

    [ -d "$logDir" ] && [ $(ls -1A "$logDir" | wc -l) -gt 0 ] || rmdir "$logDir"
    return $status
}

#----------------------------------------------------------------------------------------------
function build.canPush()
{
    local -r revision=${1:?}

    [ "${BUILD_PUSH:-0}" != 0 ] && return 0
    if [[ "$revision" = *dirty* ]]; then
        echo -n '    '
        echo -en '\e[93m'
        echo -n 'This image will not be pushed to the docker registry because it was built from a dirty repo'
        echo -e '\e[0m'
        return 1
    fi
    return 0
}

#----------------------------------------------------------------------------------------------
function build.cbfVersion()
{
    [ -d container_build_framework ] || trap.die 'No framework directory located'
    [ -e container_build_framework/.git ] || trap.die 'CBF is not a git directory'

    local filename="$(git.origin 'container_build_framework')"
    [[ "$filename" == *-dirty* ]] && return 1

    custom.cbfVersion "$filename"
    return 0
}

#----------------------------------------------------------------------------------------------
function build.changeImage()
{
    local taggedImage=${1:?}
    local actualImage=${2:?}

    [ -z "$(docker images --format '{{.Repository}}:{{.Tag}}'  --filter "reference=$taggedImage")" ] || \
        [ "$(docker ps --format '{{.Image}}' | grep "$taggedImage")" ] || \
        docker rmi "$taggedImage"

    [ -z "$(docker images --format '{{.Repository}}:{{.Tag}}' --filter "reference=$actualImage")" ] || \
        docker tag "$actualImage" "$taggedImage"
}

#---------------------------------------------------------------------------------------------- #----------------------------------------------------------------------------------------------
function build.cmdLineArgs()
{
    local base="${1:?}"
    shift
    local usage='build.usage'

    # Parse command-line options into above variable
    local -r progname="$( basename "${BASH_SOURCE[0]}" )"
    local -r options=$(getopt --longoptions "help,Help,HELP,console,force,logdir:,logfile:,push,os:" --options "Hhcfl:po:" --name "$progname" -- "$@") || "$usage" $?
    eval set -- "$options"

    local -A opts=()
    opts['base']="$(readlink -f "$base")"
    opts['logdir']="${opts['base']}/logs"
    opts['logfile']="logs/build.$(date +"%Y%m%d%H%M%S").log"
    opts['conlog']=0

    while true; do
        case "${1:-}" in
            -h|--h|--help|-help)  "$usage" 1;;
            -H|--H|--HELP|-HELP)  "$usage" 1;;
            --Help|-Help)         "$usage" 1;;
            -c|--c|--console)     opts['console']=1; shift 1;;
               --logdir)          opts['logdir']="$2"; shift 2;;
            -l|--l|--logfile)     opts['logfile']="$2"; shift 2;;
            -o|--o|--os)          opts['os']="$2"; shift 2;;
            -f|--f|--force)       opts['force']=1; shift 1;;
            -p|--p|--push)        opts['push']=1; shift 1;;
            --)                   shift; break;;
        esac
    done

    if [ -z "$(git submodule)" ];then
        term.log 'Invalid directory.' 'error'
        exit 1
    fi

    appenv.results "$@"
}

#----------------------------------------------------------------------------------------------
function build.containersForOS()
{
    local -r containerOS=${1:-}
    shift
    local -ar requestModules=( "$@" )
    [ "${containerOS:-}" ] || containerOS="${CONTAINER_OS:-alpine}"


    local osStartTime=$(timer.getTimestamp)

    export CBF_VERSION
    export CONTAINER_OS="$containerOS"
    export DEV_TEAM="${DEV_TEAM:-devops/}"
    export DOCKER_REGISTRY=$(registry.SERVER)

    if [ "${CONSOLE_LOG:-0}" -eq 0 ]; then
        PROGRESS_LOG="$(readlink -f "$logDir")/progressInfo"
        touch "$PROGRESS_LOG"
    fi

    local build_time=$(date +%Y%m%d-%H%M%S.%N -u)
    local fingerprint="n/a"
    local git_commit=$(git.HEAD)
    local git_url="$(git.remoteUrl)"
    local origin=$(git.origin)
    local git_refs="$(git.refs)"

    echo
    echo -n 'building '
    echo -en '\e[94m'
    echo -n "$git_url"
    echo -e '\e[0m'
    echo "    container OS:   $containerOS"
    echo "    refs:           (${git_refs})"
    echo "    commitId:       $git_commit"
    echo "    revision:       $origin"

    # get versions  (do not redefine any that are alresady in ENV)
    local versions="${VERSIONS_DIRECTORY}/$containerOS"
    [ -e "$versions" ] || trap.die "Unrecognized CONTAINER_OS: $containerOS"
    lib.exportFileVars "$versions"

    exec 3>&1  # create special stdout

    local -i status=0
    while read -r dir; do
        [ $status -eq 0 ] || continue
        if [ ! -d "$dir" ]; then
            echo "invalid project directory: $dir"
            continue
        fi

        pushd "$dir" >/dev/null
        build.module "$containerOS" && status=$? || status=$?
        popd >/dev/null
        [ $status -ne 0 ] && break
    done< <( build.verifyModules "$containerOS" $(printf '%s\n' "${requestModules[@]}") && status=$? || status=$?)

    exec 3>&-   # close special stdout

    # delete empty logs
    find "$logDir" -type f -size 0 -delete

    local osEndTime=$(timer.getTimestamp)
    local -i osElapsed=$(( osEndTime - osStartTime ))

    local osDuration="$(timer.fmtElapsed $osElapsed)"
    printf '\n  Time building %s OS: %s\n' "$containerOS" "$osDuration"

    [ "${CONSOLE_LOG:-0}" -eq 0 ] || :> "$PROGRESS_LOG"
    build.logToKafka "$build_time" \
                     "$fingerprint" \
                     "$git_commit" \
                     "$git_url" \
                     "$origin" \
                     "$osDuration" \
                     "$osElapsed" \
                     "$git_refs" \
                     "$containerOS"

    return $status
}

#----------------------------------------------------------------------------------------------
function build.dependencyInfo()
{
    # get the following
    #  - git tree hash
    #  - resolved 'docker build.args' config (without reference to FROM_BASE) from docker-compose.yml
    #  - container digest of layer that we are building on top of
    #  - anything dirty in workspace
    #  - sha from CBF

    # SIDE EFFECTS:
    #  - ensure any FROM_BASE is local
    #  - sets CBF_VERSION
    local -r config=${1:?}


    # git tree hash
    local dirty=' '
    [ "$(git.status --porcelain)" ] && dirty='*'
    echo "${dirty}$(sha256sum < <(git.lsTree HEAD .) | cut -d ' ' -f 1) $(basename $(pwd))"

    # resolve 'docker build.args' config (without reference to FROM_BASE) from docker-compose.yml
    set +u
    eval echo $(jq '.build.args? | del(.FROM_BASE)' <<< "$config")
    set -u


    # container digest of layer that we are building on top of
    local base=$(build.getImageParent "$config")
    docker inspect "$base" | jq '.[].Id?'          # digest sha from parent


    # anything dirty in workspace
    while read -r line; do
        local file=$(awk '{print $2}' <<< "$line")
        case $(awk '{print $1}' <<< "$line") in
            A|M|MM)
                sha256sum "$file";;
            *)
                echo "$line";;
        esac
    done < <(git.status --porcelain)

    # add our cbf version
    local localDir
    [ -d build ] && localDir="$(ls -1A build/ | grep 'container_build_framework')"
    if [ ${localDir:-} ]; then
        # generate fingerprint from all our dependencies
        echo -n 'local-'
        sha256sum <<< "$(build.dirChecksum "$localDir")" | cut -d' ' -f1

    elif [ $(basename "$(pwd)") = 'base_container' ]; then
        if [ -d "../container_build_framework" ]; then
            export CBF_VERSION=$(git.origin ../container_build_framework)
        elif [ "${CBF_VERSION:-}" ]; then
            :
        else
            die 'no version specified for CBF'
        fi
        echo "$CBF_VERSION"

    else
        # use parent's cbf.version
        docker inspect "$base" | jq -r '.[].Config.Labels."version.cbf"?'
    fi
}

#----------------------------------------------------------------------------------------------
function build.dirChecksum()
{
    local -r dir=${1:?}

    # add any local 'build/container_build_framework' folder
    while read -r file; do
        sha256sum "$file"
    done < <(find "$dir" -type f -name '*' 2>/dev/null ||:)
}

#----------------------------------------------------------------------------------------------
function build.dockerCompose()
{
    local -r compose_yaml="${1:?}"

    local jsonConfig=$( build.yamlToJson "$compose_yaml" | jq '.services?' )
    if [ "${jsonConfig:-}" ]; then
        local -r service="$(jq -r 'keys[0]?' <<< "$jsonConfig")"
        [ -z "${service:-}" ] || jq $(eval echo "'.\"$service\"?'") <<< "$jsonConfig"
    fi
}

#----------------------------------------------------------------------------------------------
function build.findIdsWithFingerprint()
{
    local -r fingerprint=${1:?}

    curl --silent \
         --unix-socket /var/run/docker.sock http://localhost/images/json \
         | jq -r ".[]|select(.Labels.\"container.fingerprint\" == \"$fingerprint\").RepoTags[]?"
}

#----------------------------------------------------------------------------------------------
function build.getImageParent()
{
    local -r config=${1:?}
    local -r unique=${2:-}

    local base=$(eval echo $( jq '.build.args.FROM_BASE?' <<< "$config" ))
    if [ -z "$(docker images --format '{{.Repository}}:{{.Tag}}' --filter "reference=$base")" ]; then
        echo pulling parent image: "$base" >&2
        [ "$(docker image ls "$base" | awk 'NR != 1')" ] || docker pull "$base" >&2 ||: return 0
    fi
    if [ "${unique:-}" ]; then
        local tag="$(docker inspect "$base" | jq -r '.[].Config.Labels."container.fingerprint"' )"
        [ -z "${tag:-}" ] || [ "$tag" =  'null' ] || [ "$tag" = "${base##*:}" ] || base="${base%:*}:$tag"
    fi
    echo "$base"
}

#----------------------------------------------------------------------------------------------
function build.logger()
{
    local msg=${1:?}

    if [ "${CONSOLE_LOG:-0}" -eq 0 ]; then
        if [[ $msg == checking* ]] || [[ $msg == *'has not changed.' ]]; then
            echo "    $msg" >&3
        else
            echo -e "    \e[32m$msg\e[0m" >&3
        fi
        echo "$msg" >> "$PROGRESS_LOG"
    fi
    echo "    $msg"
}

#----------------------------------------------------------------------------------------------
function build.logInfo()
{
    local log_time=${1:-}

    [ "$log_time" ] && echo "    build time:     ${CONTAINER_BUILD_TIME:-}"
    echo "    refs:           ${CONTAINER_GIT_REFS:-}"
    echo "    commitId:       ${CONTAINER_GIT_COMMIT:-}"
    echo "    repo:           ${CONTAINER_GIT_URL:-}"
    echo "    fingerprint:    ${CONTAINER_FINGERPRINT:-}"
    echo "    revision:       ${CONTAINER_ORIGIN:-}"
    echo "    parent:         ${CONTAINER_PARENT:-}"
}

#----------------------------------------------------------------------------------------------
function build.logImageInfo()
{
    local -r image=${1:?}
    local -r dc_yaml=${2:?}

    local containerOS="${image#*/}"
    containerOS="${containerOS%%/*}"

    local json="$(docker inspect "$image" | jq '.[].Config.Labels')"
    local depLog="${containerOS}.dependencies.log"
    [ -e "$depLog" ] || touch "$depLog"

    printf '%s :: pulling %s\n' "$(TZ='America/New_York' date)" "$image" >> "$depLog"
    echo '    refs:             '$(jq -r '."container.git.refs"' <<< "$json") >> "$depLog"
    echo '    commitId:         '$(jq -r '."container.git.commit"' <<< "$json") >> "$depLog"
    echo '    repo:             '$(jq -r '."container.git.url"' <<< "$json") >> "$depLog"
    echo '    fingerprint:      '$(jq -r '."container.fingerprint"' <<< "$json") >> "$depLog"
    echo '    parent:           '$(jq -r '."container.parent"' <<< "$json") >> "$depLog"
    echo '    revision:         '$(jq -r '."container.origin"' <<< "$json") >> "$depLog"
    echo '    build.time:       '$(jq -r '."container.build.time"' <<< "$json") >> "$depLog"
    echo '    original.name:    '$(jq -r '."container.original.name"' <<< "$json") >> "$depLog"

    build.dependencyInfo "$(build.dockerCompose "$dc_yaml")" >> "$depLog"
    printf '\n\n\n' >> "$depLog"
}

#----------------------------------------------------------------------------------------------
function build.logToKafka()
{
    if [ -z "${KAFKA_BOOTSTRAP_SERVERS:-}" ]; then
        echo 'KAFKA_BOOTSTRAP_SERVERS not defined. No metrics gathered'
        return 0
    fi

    local kafka_producer="$(which kafkaProducer.py 2>/dev/null ||:)"
    [ "$kafka_producer" ] || kafka_producer="$(dirname $(readlink -f "${BASH_SOURCE[0]}"))/kafkaProducer.py"
    if [ -z "${kafka_producer:-}" ] || [ ! -e "$kafka_producer" ]; then
        echo 'Unable to locate KAFKA_PRODUCER script. No metrics gathered'
        return 0
    fi

    local -r build_time=${1:-}
    local -r fingerprint=${2:-}
    local -r git_commit=${3:-}
    local -r git_url=${4:-}
    local -r origin=${5:-}
    local -r duration=${6:-}
    local -r elapsed=${7:-}
    local -r git_refs=${8:-}
    local -r status=${9:-}
    local -r containerOS=${10:-}

    local -a refs=( $git_refs )
    # create our data array that gets logged
    local -a build_data=( "$(json.encodeField "build_time" "$build_time")"
                          "$(json.encodeField "fingerprint" "$fingerprint")"
                          "$(json.encodeField "commit" "$git_commit")"
                          "$(json.encodeField "repo_url" "$git_url")"
                          "$(json.encodeField "origin" "$origin")"
                          "$(json.encodeField "duration" "$duration")"
                          "$(json.encodeField "elapsed" "$elapsed")"
                          "$(json.encodeArray "refs" $(json.arrayValues "${refs[@]}"))"
                          "$(json.encodeField "status" "$status")"
                          "$(json.encodeField "containerOS" "$containerOS")"
                        )
    if [ "${PROGRESS_LOG:-}" ] && [ -s "$PROGRESS_LOG" ]; then
        local -a progress_log=( $(< "$PROGRESS_LOG") )
        build_data+=("$(json.encodeArray "actions" $(json.arrayValues "${progress_log[@]}"))")
    fi


    # now log our data to kafka
    ("$kafka_producer" --server "$KAFKA_BOOTSTRAP_SERVERS"                     \
                       --topic 'container_build_data'                          \
                       --value "$( json.encodeHash '--' "${build_data[@]}" )" &) || :
    return 0
}

#----------------------------------------------------------------------------------------------
function build.module()
{
    local -r containerOS=${1:?}

    local -i moduleStartTime=$(timer.getTimestamp)

    local compose_yaml="docker-compose.yml"
    [ -e "$compose_yaml" ] || return 0
    local config=$(build.dockerCompose "$compose_yaml")


    # setup environment for 'docker-compose build'
    export CONTAINER_BUILD_TIME=$(date +%Y%m%d-%H%M%S.%N -u)
    export CONTAINER_GIT_COMMIT="$(git.HEAD)"
    export CONTAINER_GIT_REFS="($(git.refs))"
    export CONTAINER_GIT_URL="$(git.remoteUrl)"
    export CONTAINER_ORIGIN="$(git.origin)"


    # generate fingerprint from all our dependencies
    local branch=$(git.branch)
    if [ "$branch" = 'HEAD' ]; then
        local -a branches
        mapfile -t branches < <(git log -n1 --oneline --decorate | \
                                sed -e 's/[^\(]*(\([^\)]*\)).*/\1/' -e 's:origin/::g' -e 's:,::g' -e 's|tag:||g' -e 's|HEAD||g' | \
                                awk '{if(length($0)>0) {print $0}}' RS=' '| \
                                sort -u | \
                                awk '{if(length($0)>0) {print $0}}')
        if [ "${#branches[0]}" -eq 0 ]; then
            term.elog "***ERROR: failure to determine current branch for $(git.repoName). Most likely on a detached HEAD"'\n' 'warn'
            git log -8 --graph --abbrev-commit --decorate --all >&2
            return 1
        fi
        branch="${branches[0]}"
    fi
    export BASE_TAG="${BASE_TAG:-${branch//\//-}}"
    export CONTAINER_PARENT="$(build.getImageParent "$config" 'unique')"

    local taggedImage="$(eval echo $(jq '.image?' <<< $config))"
    taggedImage="${taggedImage%:*}:${BASE_TAG}"

    local -r dependencies="$(build.dependencyInfo "$config")"
    export CONTAINER_FINGERPRINT="$( sha256sum <<< "$dependencies" | cut -d' ' -f1 )"

    echo
    echo -n 'building '
    echo -en '\e[94m'
    echo -n "$taggedImage"
    echo -e '\e[0m'
    build.logInfo

    [ "${CONTAINER_FINGERPRINT:-}" ] || trap.die "No base image found for '$taggedImage'. Unable to calculate fingerprint."

    local depLog="${containerOS}.dependencies.log"
    [ -e "$depLog" ] || touch "$depLog"
    if [ $(grep -c "$CONTAINER_FINGERPRINT" "$depLog") -eq 0 ]; then
        local offs=$(grep -n ' :: building ' "$depLog" | tail -2 | awk -F':' '{if(NR==1){print ($1-1)}}')
        [ -z "$offs" ] || [ $offs -le 0 ] || sed -i -e "1,$offs d" "$depLog"
        printf '%s :: building %s\n' "$(TZ='America/New_York' date)" "$taggedImage" >> "$depLog"
        build.logInfo >> "$depLog"
        echo '  dependencies:' >> "$depLog"
        local -a deps=( $dependencies )
        printf '    %s\n' "${deps[@]}" >> "$depLog"
        printf '\n\n\n' >> "$depLog"
    fi


    # get name of image tagged with fingerprint
    export CONTAINER_TAG="$CONTAINER_FINGERPRINT"
    local actualImage="$(eval echo $(jq '.image?' <<< $config))"
    local -i status=0

    # rebuild container because no container exists with the correct fingerprint
    if [ "${CONSOLE_LOG:-0}" -eq 0 ]; then
        # this on Jenkins
        :> "$PROGRESS_LOG"
        local logBase="${logDir}/${dir}.${CONTAINER_OS}"
        [ -f "${logBase}.out.log" ] && sudo rm "${logBase}.out.log"
        [ -f "${logBase}.err.log" ] && sudo rm "${logBase}.err.log"
        build.logInfo 'include_time' > "${logBase}.out.log"
        # - use 'sed' to strip color codes from "${logBase}.out.log"
        (build.updateContainer "$compose_yaml" "$taggedImage" "$actualImage" "$CONTAINER_ORIGIN" 2>"${logBase}.err.log" \
          | sed -E 's|\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]||g' >>"${logBase}.out.log") \
          && status=$? || status=$?
        [[ $status -eq 9 || ! -s "${logBase}.out.log" ]] && rm "${logBase}.out.log"
        [ -s "${logBase}.err" ] || rm "${logBase}.err.log"


        if [ "${BUILD_URL:-}" ]; then
            # for Jenkins: show location of log files if they have any content
            local log_display_base="${BUILD_URL}artifact/$(basename "$logDir")/${dir}.${CONTAINER_OS}"
            [ -s "${logBase}.out.log" ] && echo "    STDOUT log:     ${log_display_base}.out.log/*view*/"
            [ -s "${logBase}.err.log" ] && echo "    STDERR log:     ${log_display_base}.err.log/*view*/"
        fi

        if [ $status -ne 0 ] && [ $status -ne 9 ]; then
          term.log "\n"
          term.log "***Error occurred while generating $taggedImage" 'error'
          echo
          echo '----------------------------------------------------------------------------------------------'
          echo
          echo  'STDOUT:'
          echo
          [ -e "${logBase}.out.log" ] && tail -30 "${logBase}.out.log"
          echo
          echo '----------------------------------------------------------------------------------------------'
          echo
          echo  'STDERR:'
          echo
          [ -e "${logBase}.err.log" ] && tail -30 "${logBase}.err.log"
          echo
          echo '----------------------------------------------------------------------------------------------'
        fi

    else
        (build.updateContainer "$compose_yaml" "$taggedImage" "$actualImage" "$CONTAINER_ORIGIN") && status=$? || status=$?
    fi
    local -i moduleEndTime=$(timer.getTimestamp)
    local -i moduleElapsed=$(( moduleEndTime - moduleStartTime ))
    local moduleDuration="$(timer.fmtElapsed $moduleElapsed)"
    printf '    duration:       %s\n' "$moduleDuration"

    build.logToKafka "$CONTAINER_BUILD_TIME" \
                     "$CONTAINER_FINGERPRINT" \
                     "$CONTAINER_GIT_COMMIT" \
                     "$CONTAINER_GIT_URL" \
                     "$CONTAINER_ORIGIN" \
                     "$moduleDuration" \
                     "$moduleElapsed" \
                     "$CONTAINER_GIT_REFS" \
                     "$status" \
                     "$containerOS"

    [ $status -eq 9 ] && status=0
    return $status
}

#----------------------------------------------------------------------------------------------
function build.updateContainer()
{
    local -r compose_yaml=${1:?}
    local -r taggedImage=${2:?}
    local -r actualImage=${3:?}
    local -r revision=${4:-}

    if [ "${BUILD_ALWAYS:-0}" = 0 ]; then
        build.logger "checking for local $taggedImage with the correct fingerprint"
        local -a images
        mapfile -t images < <(build.findIdsWithFingerprint "$CONTAINER_FINGERPRINT" | grep -v '<none>:<none>' || :)
        if [ ${#images[*]} -gt 0 ]; then
            build.logger "${taggedImage} has not changed."
            local -i doPush=0
            if [ $(printf '%s\n' "${images[@]}" | grep -cs "$taggedImage") -eq 0 ]; then
                # found image by a different 'name:tag'
                docker tag "${images[0]}" "$taggedImage"
                doPush=1
            elif [ "${BUILD_PUSH:-0}" != 0 ] || [ $(docker inspect "$taggedImage" | jq -r '.[].RepoDigests?|length') -eq 0 ]; then
                doPush=1
            fi
            [ $doPush -eq 0 ] || docker.pushRetained 0 "$taggedImage"
            return 9
        fi


        # check if there is an image in the registry with the correct fingerprint
        build.logger "checking if $actualImage is available in registry"
        if docker pull "$actualImage" 2>/dev/null; then
            # downloaded image from registry
            build.changeImage "$taggedImage" "$actualImage"
            build.logImageInfo "$taggedImage" "$compose_yaml"
            if [ "${BUILD_PUSH:-0}" != 0 ]; then
                build.logger "pushing ${taggedImage} to registry"
                docker.pushRetained 0 "$taggedImage"
            fi
            docker rmi "$actualImage"
            return 9
        fi
    fi

    # export any custom variables needed
    lib.exportFileVars custom.properties


    # rebuild container because no container exists with the correct fingerprint
    build.logger "building $actualImage"
    docker-compose -f "$compose_yaml" build 2>&1 || trap.die "Build failure"

    build.changeImage "$taggedImage" "$actualImage"
    [ -z "$(docker images --format '{{.Repository}}:{{.Tag}}' --filter "reference=$taggedImage")" ] && docker tag "$actualImage" "$taggedImage"

    if build.canPush "$revision"; then
        build.logger "pushing ${taggedImage} to registry"
        docker.pushRetained 0 "$taggedImage"
    fi
    docker rmi "$actualImage"
    return 0
}

#----------------------------------------------------------------------------------------------
function build.verifyModules()
{
    local -r containerOS=${1:?}
    shift
    local -a requestedModules=( "$@" )
    [ "${#requestedModules[*]}" -gt 0 ] || requestedModules=()
    local -r skip_builds_file='skip.build'

    local -a modules=( $(grep -Ev '^\s*#' "$VERSIONS_DIRECTORY/${containerOS}.modules") )
    local retval=1
    for defMod in "${modules[@]}"; do
        [ -d "$defMod" ] && [ -e "${defMod}/docker-compose.yml" ] || continue
        [ -e "$skip_builds_file" ] && [ $(grep -cHE "^$defMod\s*$" "$skip_builds_file" 2>/dev/null | cut -d':' -f2) -gt 0 ] && continue

        local definedOS=$(grep -E '^#\s+containerOS:\s+' "${defMod}/docker-compose.yml" ||:)
        [ "${definedOS:-}" ] && [ $(grep -cH "$containerOS" <<< "$definedOS" | awk -F ':' '{print $2}') -eq 0 ] && continue

        if [ "${#requestedModules[*]}" -eq 0 ]; then
            echo "$defMod"
            retval=0
            continue
        fi

        for reqMod in "${requestedModules[@]}"; do
            [ "$reqMod" = "$defMod" ] || continue
            retval=0
            echo "$defMod"
        done
    done
    return "$retval"
}

#----------------------------------------------------------------------------------------------
function build.wrapper()
{
    local -A opts
    eval opts=( $1 )
    readonly opts
    shift


    export CONSOLE_LOG="${opts['conlog']:-0}"
    [ "${opts['force']:-}" ]  && export BUILD_ALWAYS="${opts['force']}"
    [ "${opts['push']:-}" ]   && export BUILD_PUSH="${opts['push']}"
    [ "${opts['os']:-}" ]     && export CONTAINER_OS="${opts['os']}"


    local -i status=0
    if [ "${opts['logfile']:-}" ]; then
        mkdir -p "$(dirname "${opts['logfile']}")"
        eval echo 'build.all "${opts['base']}" "${opts['logdir']}" "$@" 2>&1 | tee '"${opts['logfile']}"
        (build.all "${opts['base']}" "${opts['logdir']}" "$@" 2>&1 | tee "${opts['logfile']}") && status=$? || status=$?
    else
        eval echo 'build.all "${opts['base']}" "${opts['logdir']}" "$@"'
        (build.all "${opts['base']}" "${opts['logdir']}" "$@") && status=$? || status=$?
    fi
    return $status
}

#----------------------------------------------------------------------------------------------
function build.yamlToJson()
{
    local -r yamlFile=${1:?}
    local -a YAML_TO_JSON=( 'python' '-c' 'import sys, yaml, json; json.dump(yaml.load(sys.stdin), sys.stdout, indent=4)' )

    if [ -e "$yamlFile"  ]; then
        "${YAML_TO_JSON[@]}" < "$yamlFile"

    elif [[ "$yamlFile" == http* ]]; then
        "${YAML_TO_JSON[@]}" <<< "$(curl --insecure --silent --request GET "$yamlFile")"

    else
        "${YAML_TO_JSON[@]}" <<< "$yamlFile"
    fi
}

#----------------------------------------------------------------------------------------------
#
#      MAIN
#
#----------------------------------------------------------------------------------------------

declare -i status
declare -a args
declare fn=build.wrapper

declare loader="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/appenv.bashlib"
if [ ! -e "$loader" ]; then
    echo 'Unable to load libraries'
    exit 1
fi
source "$loader"
appenv.loader "$fn"

args=$( build.cmdLineArgs "$TOP" "$@" ) && status=$? || status=$?
[ $status -eq 0 ] || exit $status
"$fn" ${args[@]}
