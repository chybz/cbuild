set -e

# Check BASH version
if [ "${BASH_VERSINFO[0]}" -ne 4 ]; then
    echo "Bash version 4 or greater is needed (you have: $BASH_VERSION)"
    exit 1
fi

# Check cpkg-config is available
if [ -z "$CPKG_HOME" ]; then
    if ! which cpkg-config >/dev/null; then
        echo "cpkg-config not found, please install cpkg"
        exit 1
    fi
elif ! [ -x $CPKG_HOME/bin/cpkg-config ]; then
    echo "$CPKG_HOME is not a valid cpkg directory"
    exit 1
fi

ACTION=""
STATUS=1

function handle_trap() {
    local SIG="$1"

    local MSG
    local FUNC

    if [[ $SIG == "EXIT" ]]; then
        exit 0
    elif [[ $SIG == "INT" || $SIG == "TERM" ]]; then
        MSG="aborted"
        FUNC="cp_error"
        trap '' EXIT
    elif (($STATUS)); then
        if [ -z "$ACTION" ]; then
            MSG="abnormal termination"
        else
            MSG="$ACTION failed"
        fi

        FUNC="cp_error"
    else
        if [ -z "$ACTION" ]; then
            MSG="OK"
        else
            MSG="$ACTION OK"
        fi

        FUNC="cp_msg"
    fi

    if [[ -n "$FUNC" ]]; then
        eval "$FUNC $MSG"
    fi

    exit $STATUS
}

function trap_with_arg() {
    local FUNC="$1"
    shift

    for SIG; do
        trap "$FUNC $SIG" "$SIG"
    done
}

trap_with_arg handle_trap INT TERM EXIT

##############################################################################
#
# Global variables
#
##############################################################################

TOPDIR=$(pwd)
CBUILD_CONF=cbuild.conf

# Map target type to directory name
declare -A TYPE_DIRS=(
    [BIN]=binaries
    [TST]=tests
    [LIB]=libraries
    [PLUG]=plugins
    [INC]=include
)
declare -a BIN_TARGETS
declare -a BIN_ONLY_TARGETS
declare -a SVC_TARGETS
declare -a TST_TARGETS
declare -a LIB_TARGETS
declare -a PLUG_TARGETS
declare -A PLUG_CLASSES
declare -A TARGET_TYPE_MAP
declare -A TARGET_HEADER_MAP
declare -A TARGET_DEP_MAP
declare -A TARGET_PKGDEP_MAP
declare -A TARGET_PCDEP_MAP
declare -A TARGET_RUNTIME_PCDEP_MAP
declare -A TARGET_DEP_HIST
declare -A TARGET_LIBDIRS
declare -A HLIB_TARGET_MAP
declare -A PLIB_TARGET_MAP
declare -A NOINST_TARGET_MAP
declare -A NOT_FOUND_MAP
declare -A STD_HEADERS
declare -a PRJ_HEADER_DIRS
declare -A PRJ_MANPAGES
declare -A PRJ_LOCAL_PKGCONFIGS
declare -A PRJ_OPTS
declare -a PRJ_CFLAGS
declare -a PRJ_CXXFLAGS
declare -a PRJ_LFLAGS
declare -A PRJ_PKGS
declare -A PRJ_RUNTIME_PKGS
declare -A PRJ_AUTOLINK
declare -a PRJ_NOCOV
declare -a PRJ_PRIVATE_LIBS
declare -A PRJ_HAS=(
    [BIN]=0
    [BIN_ONLY]=0
    [SVC]=0
    [TST]=0
    [LIB]=0
    [PLUG]=0
    [BIN_LIB]=0
    [ETCDIR]=0
    [SYSETCDIR]=0
    [SHAREDIR]=0
    [SYSSHAREDIR]=0
)

# Set defaults
PRJ_SRCDIR=$TOPDIR/sources
PRJ_BUILDDIR=$TOPDIR/build
PRJ_BATSDIR=$TOPDIR/bats
PRJ_HAS_BATS=0
PRJ_ETCDIR=$TOPDIR/etc
PRJ_SYSETCDIR=$TOPDIR/etc_
PRJ_SHAREDIR=$TOPDIR/share
PRJ_SYSSHAREDIR=$TOPDIR/share_
PRJ_BINDIR=$PRJ_BUILDDIR/bin
PRJ_TSTDIR=$PRJ_BUILDDIR/t
PRJ_BINTSTDIR=$PRJ_TSTDIR
PRJ_BATSTSTDIR=$PRJ_TSTDIR
PRJ_LIBDIR=$PRJ_BUILDDIR/lib
PRJ_PLUGDIR=$PRJ_BUILDDIR/lib/plugins
PRJ_GENINCNAME=${TYPE_DIRS[INC]}.generated
PRJ_GENINCDIR=$PRJ_BUILDDIR/${PRJ_GENINCNAME}
PRJ_INCNAME=${TYPE_DIRS[INC]}
PRJ_INCDIR=$PRJ_BUILDDIR/${PRJ_INCNAME}
PRJ_PRIVINCNAME=${TYPE_DIRS[INC]}.private
PRJ_PRIVINCDIR=$PRJ_BUILDDIR/${PRJ_PRIVINCNAME}
PRJ_TARGET="none"
PRJ_USER=root
PRJ_GROUP=$PRJ_USER

if [[ -f $CBUILD_CONF ]]; then
    . $CBUILD_CONF
    [[ -z "$PKG_VER" ]] && PKG_VER=1.0
    (($PKG_REV)) || PKG_REV=1

    for LIB in ${PRJ_PRIVATE_LIBS[@]}; do
        PLIB_TARGET_MAP[$LIB]=1
    done

    [[ -n "$PRJ_NAME" ]] || (echo "PRJ_NAME not set" && exit 1)
fi

PKG_NAME=${PRJ_NAME//_/-}
PRJ_DEFPREFIX="${PRJ_NAME^^}_"
PRJ_DEFPREFIX="${PRJ_DEFPREFIX//-/_}"

if [ -z "$CPKG_HOME" ]; then
    . $(cpkg-config -L)
else
    . $($CPKG_HOME/bin/cpkg-config -L)
fi

PROJECT_VARS="PRJ_NAME"
PROJECT_VARS+=" PKG_SHORTDESC PKG_LONGDESC PRJ_TARGET PRJ_DEFPREFIX"
PROJECT_DIRS="PRJ_SRCDIR PRJ_BUILDDIR PRJ_BATSDIR"
PROJECT_DIRS+=" PRJ_BINDIR PRJ_TSTDIR PRJ_BINTSTDIR PRJ_BATSTSTDIR"
PROJECT_DIRS+=" PRJ_LIBDIR PRJ_PLUGDIR"
PROJECT_DIRS+=" PRJ_GENINCDIR PRJ_INCDIR PRJ_PRIVINCDIR"
PROJECT_VARS+=" PRJ_GENINCNAME PRJ_INCNAME PRJ_PRIVINCNAME"
PROJECT_VARS+=" PRJ_USER PRJ_GROUP PRJ_HAS_BATS"
CB_TMPL_VARS="TOPDIR $PROJECT_VARS $PROJECT_DIRS"
export $CB_TMPL_VARS

# Regular expressions used to find a target source files
CB_SRC_RE=".*\.(c|cc|cpp|cxx)"
CB_HDR_RE=".*\.(h|hh|hpp|hxx|inl|ipp)"

CB_STATE_DIR=$(pwd)/.cbuild

export CB_CC_IS_GCC=0
export CB_CC_IS_CLANG=0
export CB_TOOLCHAIN=""
export CB_CPUS

if [[ -z "$CB_CPUS" ]]; then
    CB_CPUS=0
fi

declare -A GCC_CMDS=(
    [CPP]=cpp
    [CC]=gcc
    [CXX]=g++
    [GCOV]=gcov
)

declare -A CLANG_CMDS=(
    [CPP]=cpp
    [CC]=clang
    [CXX]=clang++
    [GCOV]=gcov
)

# Default compiler toolchains
declare -A CB_TOOLCHAINS=(
    [Linux]=gcc
    [Darwin]=clang
)

# jemalloc package name
declare -A CB_JEMALLOC_PKGS=(
    [Linux]=libjemalloc-dev
    [Darwin]=""
)

CB_EMPTY_DIR=$CB_STATE_DIR/empty-dir
CB_LOG_DIR=$CB_STATE_DIR/log

CB_COMMON_SCAN_ARGS="-x c++ -M -MG -MT CBUILD_SOURCE"
CB_COMMON_SCAN_ARGS+=" -nostdinc -nostdinc++"
CB_COMMON_SCAN_ARGS+=" -DCBUILD_SCAN -D${CPKG_PF^^} -D${CPKG_OS^^}"
CB_COMMON_SCAN_ARGS+=" -I$CB_EMPTY_DIR"

declare -A CB_SCAN_ARGS=(
    [Linux]="$CB_COMMON_SCAN_ARGS"
    [Darwin]="$CB_COMMON_SCAN_ARGS"
)

CB_SCAN_ORDER="LIB PLUG BIN TST"

declare -a CB_GEN_FLAGS
declare -a CB_LFLAGS
declare -a CB_BIN_LFLAGS
declare -a CB_LIB_CFLAGS
declare -a CB_LIB_LFLAGS
declare -a CB_CFLAGS
declare -a CB_CXXFLAGS

# Default compiler commands
export CB_CPP=""
export CB_CC=""
export CB_CXX=""
export CB_GCOV=""

# Default generator
export CB_GEN=""

# Load autolink definitions
declare -A CB_AUTOLINK
declare -A CB_AUTOLINK_GROUP

function cb_check_conf() {
    if [[ -f $CBUILD_CONF ]]; then
        cp_ensure_vars_are_set $PROJECT_VARS
    fi
}

function cb_load_autolink() {
    local FILE=$1

    [ -f $FILE ] || return 0

    local GROUP=$(basename $FILE .conf)

    local -A AUTOLINK
    . $FILE

    local RE

    for RE in ${!AUTOLINK[@]}; do
        # Resolve full package names
        local -a SPEC=(${AUTOLINK[$RE]})
        #SPEC[1]=$(lp_full_pkg_name ${SPEC[1]})
        CB_AUTOLINK[$RE]="${SPEC[@]}"
        CB_AUTOLINK_GROUP[$RE]=${GROUP^^}
    done
}

function cb_load_autolinks() {
    local FILE

    for FILE in $@; do
        cb_load_autolink $FILE
    done
}

cb_load_autolink $ETCDIR/autolink.conf
cb_load_autolinks $ETCDIR/autolink.d/*.conf
cb_load_autolinks $ETCDIR/autolink.d/$CPKG_TYPE/*.conf

##############################################################################
#
# Target scanning functions
#
##############################################################################

function cb_find_cpus() {
    local CPUS=1

    if [[ $CPKG_OS == "Linux" ]]; then
        CPUS=$(nproc)
    elif [[ $CPKG_OS == "Darwin" ]]; then
        CPUS=$(/usr/sbin/sysctl machdep.cpu.core_count | cut -d : -f 2)
        CPUS=${CPUS## }
        CPUS=${CPUS%% }
    fi

    if ! [[ "$CB_CPUS" =~ ^[[:digit:]]+$ ]]; then
        cp_error "invalid number of CPUs: $CB_CPUS"
    fi

    if (($CB_CPUS == 0 || $CB_CPUS > $CPUS)); then
        CB_CPUS=$CPUS
    fi

    cp_msg "using $CB_CPUS CPU core(s)"
}

function cb_update_caches() {
    if (($CB_NO_SCAN)); then
        return
    fi

    cp_msg "updating system caches"
    lp_make_pkg_map
    lp_make_pkg_header_map
    lp_make_pkgconfig_map
}

function cb_add_deps() {
    local TYPE=$1
    local TARGET=$2
    shift 2
    local DEP

    local TARGET_KEY="${TYPE}_${TARGET}"

    for DEP in $@; do
        TARGET_DEP_HIST[$DEP]=$((${TARGET_DEP_HIST[$DEP]} + 1))

        if [[ "${TARGET_DEP_MAP[$TARGET_KEY]}" ]]; then
            TARGET_DEP_MAP[$TARGET_KEY]+=" $DEP"
        else
            TARGET_DEP_MAP[$TARGET_KEY]=$DEP
        fi

        cp_msg "$TYPE $TARGET => LIB $DEP"
    done
}

function cb_add_pkg_deps() {
    local TYPE=$1
    local TARGET=$2
    shift 2
    local DEP

    local TARGET_KEY="${TYPE}_${TARGET}"

    for DEP in $@; do
        PRJ_PKGS[$DEP]=1

        if [[ "${TARGET_PKGDEP_MAP[$TARGET_KEY]}" ]]; then
            TARGET_PKGDEP_MAP[$TARGET_KEY]+=" $DEP"
        else
            TARGET_PKGDEP_MAP[$TARGET_KEY]=$DEP
        fi

        cp_msg "$TYPE $TARGET => PKG $DEP"
    done
}

function cb_add_pc_deps() {
    local TYPE=$1
    local TARGET=$2
    shift 2
    local DEP

    local TARGET_KEY="${TYPE}_${TARGET}"

    for DEP in $@; do
        if [[ "${TARGET_PCDEP_MAP[$TARGET_KEY]}" ]]; then
            TARGET_PCDEP_MAP[$TARGET_KEY]+=" $DEP"
        else
            TARGET_PCDEP_MAP[$TARGET_KEY]=$DEP
        fi

        cp_msg "$TYPE $TARGET => PC $DEP"
    done
}

function cb_add_runtime_pc_deps() {
    local TYPE=$1
    local TARGET=$2
    shift 2
    local DEP

    local TARGET_KEY="${TYPE}_${TARGET}"

    for DEP in $@; do
        if [[ "${TARGET_RUNTIME_PCDEP_MAP[$TARGET_KEY]}" ]]; then
            TARGET_RUNTIME_PCDEP_MAP[$TARGET_KEY]+=" $DEP"
        else
            TARGET_RUNTIME_PCDEP_MAP[$TARGET_KEY]=$DEP
        fi
    done
}

function cb_get_target_file() {
    local TYPE=$1
    local TARGET=$2
    local NAME=$3

    echo $CB_STATE_DIR/$TYPE/$TARGET/$NAME
}

function cb_get_target_output_name() {
    local TYPE=$1
    local TARGET=$2

    local NAME="$TARGET"

    if [[ $TYPE == "LIB" && ${PLIB_TARGET_MAP[$TARGET]} == 1 ]]; then
        # Prepend project name to avoid possible name clash with
        # an existing system library (embedded external library case)
        NAME="${PRJ_NAME,,}_$TARGET"
    fi

    echo $NAME
}

function cb_get_target_build_name() {
    local TYPE=$1
    local TARGET=$2

    local NAME="${TYPE,,}_"
    NAME+="$(cb_get_target_output_name $TYPE $TARGET)"

    echo $NAME
}

function cb_get_target_dir() {
    local TYPE=$1
    local TARGET=$2
    local KIND=$3

    if [ $KIND = "SOURCES" ]; then
        echo $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$TARGET
    elif [ $KIND = "HEADERS" ]; then
        echo $PRJ_SRCDIR/${TYPE_DIRS[INC]}/$TARGET
    fi
}

# Save target sources/headers info
function cb_save_target_list() {
    local TYPE=$1
    local TARGET=$2
    local NAME=$3
    shift 3

    local FILE=""

    if [[ $NAME =~ ^\+ ]]; then
        # Append mode
        NAME=${NAME#\+}
        FILE="+"
    fi

    FILE+=$(cb_get_target_file $TYPE $TARGET $NAME)

    cp_save_list $NAME $FILE "$@"
}

# Save target sources/headers info
function cb_save_target_var() {
    local TYPE=$1
    local TARGET=$2
    local NAME=$3
    local VAR=$4
    shift 4

    local FILE=$(cb_get_target_file $TYPE $TARGET ${NAME#\+})

    if [[ ! $NAME =~ ^\+ ]]; then
        # Overwrite mode
        > $FILE
    fi

    echo "$VAR=\"$@\"" >> $FILE
}

function cb_set_noinst() {
    local NAME=$1

    ((${NOINST_TARGET_MAP[$NAME]})) && return 0

    NOINST_TARGET_MAP[$NAME]=0

    local SRCDIR=$PRJ_SRCDIR/${TYPE_DIRS[BIN]}/$NAME
    local HDRDIR=$PRJ_SRCDIR/${TYPE_DIRS[INC]}/$NAME

    [[ -d $SRCDIR && -f $SRCDIR/.cbuild_noinst ]] && NOINST_TARGET_MAP[$NAME]=1
    [[ -d $HDRDIR && -f $HDRDIR/.cbuild_noinst ]] && NOINST_TARGET_MAP[$NAME]=1

    return 0
}

function cb_set_is_private_lib() {
    local NAME=$1

    ((${PLIB_TARGET_MAP[$NAME]})) && return 0

    PLIB_TARGET_MAP[$NAME]=0

    local SRCDIR=$PRJ_SRCDIR/${TYPE_DIRS[LIB]}/$NAME
    local HDRDIR=$PRJ_SRCDIR/${TYPE_DIRS[INC]}/$NAME

    [[ -d $SRCDIR && -f $SRCDIR/.cbuild_private ]] && PLIB_TARGET_MAP[$NAME]=1
    [[ -d $HDRDIR && -f $HDRDIR/.cbuild_private ]] && PLIB_TARGET_MAP[$NAME]=1

    return 0
}

function cb_is_private_lib() {
    local NAME=$1

    return ${PLIB_TARGET_MAP[$NAME]}
}

function cb_scan_target() {
    local TYPE=$1
    local NAME=$2

    PRJ_HAS[$TYPE]=1

    local -a SOURCES=($(
        cp_find_re_rel \
            $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$NAME \
            $CB_SRC_RE
    ))

    if ((${#SOURCES[@]} == 0)); then
        if [[ $TYPE == "BIN" || $TYPE == "TST" ]]; then
            # Ignore binaries and tests directories without sources
            return
        fi
    fi

    cb_save_target_list $TYPE $NAME "SOURCES"

    local NOT_A_SERVICE=1
    local SOURCE SOURCEFILE

    if [ $TYPE = "BIN" ]; then
        cb_set_noinst $NAME

        if grep \
            -REq \
            "^\s*//\s*cbuild-service:\s*yes\s*$" \
            $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$NAME/*; then
            SVC_TARGETS+=($NAME)
            PRJ_HAS["SVC"]=1
            NOT_A_SERVICE=0
        fi

        for SOURCE in ${SOURCES[@]}; do
            SOURCEFILE=$PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$NAME/$SOURCE

            if grep -REq "^=pod\s*$" $SOURCEFILE; then
                PRJ_MANPAGES[$NAME]=$SOURCEFILE
                break;
            fi
        done
    fi

    local LOCAL_HEADERS=$(
        cp_find_re_rel $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$NAME $CB_HDR_RE
    )

    if [[ \
        $TYPE == "TST" \
        && \
        -d $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/${TYPE_DIRS[INC]} \
    ]]; then
        # Common tests headers
        LOCAL_HEADERS+=$(
            cp_find_re_rel \
                $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/${TYPE_DIRS[INC]} \
                $CB_HDR_RE
        )
    fi

    cb_save_target_list \
        $TYPE $NAME \
        "LOCAL_HEADERS" \
        $(cp_find_re_rel $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$NAME $CB_HDR_RE)

    local TARGET_HEADERS

    if [ $TYPE = "LIB" ]; then
        cb_set_is_private_lib $NAME

        # Only libraries have "public" headers
        TARGET_HEADERS=$(
            cp_find_re_rel \
            $PRJ_SRCDIR/${TYPE_DIRS[INC]}/$NAME \
            $CB_HDR_RE
        )
    fi

    cb_save_target_list \
        $TYPE $NAME \
        "HEADERS" \
        $TARGET_HEADERS

    TARGET_TYPE_MAP[$NAME]=$TYPE
    TARGET_DEP_HIST[$NAME]=0

    local HEADER

    for HEADER in $TARGET_HEADERS; do
        TARGET_HEADER_MAP[$HEADER]=$NAME
    done

    if [ $TYPE = "BIN" ]; then
        BIN_TARGETS+=($NAME)

        if (($NOT_A_SERVICE)); then
            BIN_ONLY_TARGETS+=($NAME)
            PRJ_HAS["BIN_ONLY"]=1
        fi
    elif [ $TYPE = "TST" ]; then
        TST_TARGETS+=($NAME)
    elif [ $TYPE = "LIB" ]; then
        LIB_TARGETS+=($NAME)

        if [ -d $PRJ_SRCDIR/${TYPE_DIRS[INC]}/$NAME ]; then
            PRJ_HEADER_DIRS+=($PRJ_SRCDIR/${TYPE_DIRS[INC]}/$NAME)
        fi
    elif [ $TYPE = "PLUG" ]; then
        PLUG_TARGETS+=($NAME)
    fi

    cp_msg "$TYPE $NAME"
}

function cb_scan_targets() {
    local TYPE=$1

    local TYPE_DIR=${TYPE_DIRS[$TYPE]}

    if [ $TYPE = "LIB" ]; then
        # Libraries have sources and/or headers
        [[ \
            -d $PRJ_SRCDIR/$TYPE_DIR \
            || \
            -d $PRJ_SRCDIR/${TYPE_DIRS[INC]} \
        ]] || return 0
    else
        # Other targets must have sources
        [[ -d $PRJ_SRCDIR/$TYPE_DIR ]] || return 0
    fi

    local NAME

    if [ $TYPE = "LIB" ]; then
        # Scan for header-only libraries
        for NAME in $PRJ_SRCDIR/${TYPE_DIRS[INC]}/*; do
            NAME=$(basename $NAME)

            if [ \
                ! -d $PRJ_SRCDIR/${TYPE_DIRS[INC]}/$NAME \
                -o \
                -d $PRJ_SRCDIR/$TYPE_DIR/$NAME \
            ]; then
                # Ignore all but directories and libraries with sources
                PRJ_HAS["BIN_LIB"]=1
                continue
            fi

            HLIB_TARGET_MAP[$NAME]=1

            cb_scan_target $TYPE $NAME
        done
    fi

    for NAME in $PRJ_SRCDIR/$TYPE_DIR/*; do
        NAME=$(basename $NAME)

        if [ ! -d $PRJ_SRCDIR/$TYPE_DIR/$NAME ]; then
            # Ignore all but directories
            continue
        elif [[ $TYPE == "TST" && $NAME == "include" ]]; then
            # Ignore tests private include directory
            continue
        fi

        cb_scan_target $TYPE $NAME
    done

    cp_save_list \
        "HEADER_DIRS" \
        $CB_STATE_DIR/PRJ/HEADER_DIRS \
        ${PRJ_HEADER_DIRS[@]}
}

function cb_scan() {
    local TYPE

    if [ -d $PRJ_ETCDIR ]; then
        PRJ_HAS["ETCDIR"]=1
    fi

    if [ -d $PRJ_SYSETCDIR ]; then
        PRJ_HAS["SYSETCDIR"]=1
    fi

    if [ -d $PRJ_SHAREDIR ]; then
        PRJ_HAS["SHAREDIR"]=1
    fi

    if [ -d $PRJ_SYSSHAREDIR ]; then
        PRJ_HAS["SYSSHAREDIR"]=1
    fi

    local OLD_TMPL_VARS="$CPKG_TMPL_VARS"
    CPKG_TMPL_VARS+=" $CB_TMPL_VARS"

    cp_process_templates $SHAREDIR/templates/cbuild/PRJ

    CPKG_TMPL_VARS="$OLD_TMPL_VARS"

    for TYPE in $CB_SCAN_ORDER; do
        if [[ $TYPE == "TST" && ${PRJ_OPTS[tests]} -eq 0 ]]; then
            continue
        fi

        cb_scan_targets $TYPE
    done
}

function cb_find_std_headers() {
    local FILTER

    if (($CB_CC_IS_CLANG)); then
        FILTER="c\+\+|clang"
    elif (($CB_CC_IS_GCC)); then
        FILTER="c\+\+|gcc"
    fi

    local INCDIRS=$(
        $CB_CPP -xc++ -Wp,-v -fsyntax-only </dev/null 2>&1 \
        | egrep "^ /" \
        | egrep "($FILTER)" \
        | xargs
    )

    local INCDIR
    local INC

    for INCDIR in $INCDIRS; do
        [ -d $INCDIR ] || continue

        for INC in $(cp_find_rel $INCDIR); do
            STD_HEADERS[$INC]=1
        done
    done

    if [[ $CPKG_TYPE == "pkgsrc" && -d "/usr/include" ]]; then
        for INC in $(cp_find_rel "/usr/include"); do
            if [ -f $CPKG_PREFIX/include/$INC ]; then
                # Prefer include from pkgsrc
                continue
            fi

            STD_HEADERS[$INC]=1
        done
    fi
}

function cb_configure_compiler_flags() {
    set +e

    if ((${PRJ_OPTS[timings]})); then
        CB_GEN_FLAGS+=("-Q" "-ftime-report")
    fi

    if [[ ${PRJ_OPTS[std]} ]]; then
        CB_CXXFLAGS+=("-std=${PRJ_OPTS[std]}")
    fi

    if ((${PRJ_OPTS[debug]})); then
        CB_GEN_FLAGS+=("-DDEBUG")
    fi

    if (($CB_CC_IS_CLANG)); then
        CB_CXXFLAGS+=("-Wno-unused-local-typedef")
        CB_CXXFLAGS+=("-stdlib=libc++" "-ftemplate-depth=512")
        CB_CXXFLAGS+=("-Qunused-arguments" "-fcolor-diagnostics")
        CB_CFLAGS+=("-Qunused-arguments" "-fcolor-diagnostics")
    elif (($CB_CC_IS_GCC)); then
        local VER=$($CB_CC -v 2>&1 | grep "gcc version" | cut -d ' ' -f 3)

        if [[ "$VER" =~ ^6\. ]]; then
            CB_CXXFLAGS+=("-fdiagnostics-color=always")
            CB_CFLAGS+=("-fdiagnostics-color=always")
        fi
    fi

    if (($CB_CC_IS_GCC)); then
        CB_GEN_FLAGS+=("-g3" "-ggdb3" "-pthread")
    else
        CB_GEN_FLAGS+=("-g")
    fi

    CB_GEN_FLAGS+=("-pipe" "-Wall")

    if [[ -z "${PRJ_OPTS[auto_export]}" ]]; then
        CB_LIB_CFLAGS+=("-fvisibility=hidden" "-fvisibility-inlines-hidden")
    fi

    [[ ${PRJ_OPTS[ide]} ]] && CB_GEN_FLAGS+=("-fmessage-length=0")

    if ((${PRJ_OPTS[asan]})); then
        CB_GEN_FLAGS+=("-fsanitize=address")
    elif ((${PRJ_OPTS[tsan]})); then
        CB_GEN_FLAGS+=("-fsanitize=thread" "-fPIE")
        CB_BIN_LFLAGS+=("-pie")
    fi

    if ((${PRJ_OPTS[lsan]})); then
        CB_GEN_FLAGS+=("-fsanitize=leak")
    fi

    if ((${PRJ_OPTS[usan]})); then
        CB_GEN_FLAGS+=("-fsanitize=undefined")
    fi

    if (($CPKG_IS_DEB)); then
        CB_BIN_LFLAGS+=("-Wl,-z,relro" "-Wl,--as-needed")
        CB_LIB_LFLAGS+=("-Wl,-z,relro" "-Wl,--as-needed")
    fi

    if (($CPKG_IS_PKGSRC)); then
        CB_LFLAGS+=("-L$CPKG_PREFIX/lib")
    fi

    [[ $CPKG_BIN_ARCH == "x86_64" ]] && CB_GEN_FLAGS+=("-fPIC")

    if [[ $CPKG_TYPE == "pkgsrc" ]]; then
        CB_CFLAGS+=("-I$CPKG_PREFIX/include")
        CB_CXXFLAGS+=("-I$CPKG_PREFIX/include")
    fi

    if ((${PRJ_OPTS[stack_protector]})); then
        CB_GEN_FLAGS+=("-fstack-protector-all")
        (($CPKG_IS_DEB)) && CB_GEN_FLAGS+=(
            "--param=ssp-buffer-size=4"
            "-fstack-check"
        )
    fi

    if ((${PRJ_OPTS[coverage]})); then
        CB_GEN_FLAGS+=("-O0" "--coverage")
        CB_LFLAGS+=("--coverage")
    elif ((${PRJ_OPTS[profiling]})); then
        CB_GEN_FLAGS+=("-O0" "-pg")
        CB_LFLAGS+=("-pg")
    elif ((${PRJ_OPTS[optimize]})); then
        CB_GEN_FLAGS+=("-O3")
    else
        CB_GEN_FLAGS+=("-Og")
    fi

    if [[ $CPKG_BIN_ARCH == "x86_64" ]]; then
        CB_GEN_FLAGS+=(
            "-msse" "-msse2"
            "-msse3" "-mssse3"
            "-msse4.1" "-msse4.2"
        )

        if ((${PRJ_OPTS[avx2]})); then
            CB_GEN_FLAGS+=("-mavx")
            CB_GEN_FLAGS+=("-mavx2")
        elif ((${PRJ_OPTS[avx]})); then
            CB_GEN_FLAGS+=("-mavx")
        fi

        (($CB_CC_IS_GCC)) && CB_GEN_FLAGS+=("-mfpmath=sse")
    elif [[ $CPKG_BIN_ARCH == "i386" ]]; then
        CB_GEN_FLAGS+=(
            "-march=prescott"
            "-msse" "-msse2" "-msse3"
            "-mfpmath=sse"
        )
    fi

    # Add user specified flags
    CB_CFLAGS+=(${PRJ_CCFLAGS[@]})
    CB_CXXFLAGS+=(${PRJ_CXXFLAGS[@]})
    CB_LFLAGS+=(${PRJ_LFLAGS[@]})
    set -e
}

function cb_configure_compiler() {
    if [[ -z "$CB_TOOLCHAIN" ]]; then
        CB_TOOLCHAIN=${CB_TOOLCHAINS[$CPKG_OS]}
    fi

    if [[ "$CB_TOOLCHAIN" =~ ^(gcc|clang)-(.+)$ ]]; then
        CB_TOOLCHAIN=${BASH_REMATCH[1]}
        CB_TOOLCHAIN_VER=${BASH_REMATCH[2]}
    fi

    if ! [[ "$CB_TOOLCHAIN" =~ ^(gcc|clang)$ ]]; then
        cp_error "invalid toolchain: $CB_TOOLCHAIN"
    fi

    case $CB_TOOLCHAIN in
        gcc)
            CB_CPP=${GCC_CMDS[CPP]}
            CB_CC=${GCC_CMDS[CC]}
            CB_CXX=${GCC_CMDS[CXX]}
            CB_GCOV=${GCC_CMDS[GCOV]}
            CB_CC_IS_GCC=1
            CB_GCC_VER=$($CB_CC -v 2>&1 | grep "^gcc version" | cut -d ' ' -f 3)
            ;;
        clang)
            CB_CPP=${CLANG_CMDS[CPP]}
            CB_CC=${CLANG_CMDS[CC]}
            CB_CXX=${CLANG_CMDS[CXX]}
            CB_GCOV=${CLANG_CMDS[GCOV]}
            CB_CC_IS_CLANG=1
            ;;
    esac

    if [[ -n "$CB_TOOLCHAIN_VER" ]]; then
        CB_CPP+="-$CB_TOOLCHAIN_VER"
        CB_CC+="-$CB_TOOLCHAIN_VER"
        CB_CXX+="-$CB_TOOLCHAIN_VER"
        CB_GCOV+="-$CB_TOOLCHAIN_VER"
    fi

    if ((${PRJ_OPTS[coverage]})); then
        CB_GCOV=${CB_GCOVS[$CPKG_OS]}
    fi

    cb_find_std_headers
    cb_configure_compiler_flags

    local CCVARS=$CB_STATE_DIR/PRJ/CCVARS
    cp_save_list "CB_GEN_FLAGS" $CCVARS ${CB_GEN_FLAGS[@]}
    cp_save_list "CB_LFLAGS" "+$CCVARS" ${CB_LFLAGS[@]}
    cp_save_list "CB_BIN_LFLAGS" "+$CCVARS" ${CB_BIN_LFLAGS[@]}
    cp_save_list "CB_LIB_CFLAGS" "+$CCVARS" ${CB_LIB_CFLAGS[@]}
    cp_save_list "CB_LIB_LFLAGS" "+$CCVARS" ${CB_LIB_LFLAGS[@]}
    cp_save_list "CB_CFLAGS" "+$CCVARS" ${CB_CFLAGS[@]}
    cp_save_list "CB_CXXFLAGS" "+$CCVARS" ${CB_CXXFLAGS[@]}
    echo "CB_CPP=$CB_CPP" >> $CCVARS
    echo "CB_CC=$CB_CC" >> $CCVARS
    echo "CB_CXX=$CB_CXX" >> $CCVARS
    echo "CB_GCOV=$CB_GCOV" >> $CCVARS
    echo "CB_CPUS=$CB_CPUS" >> $CCVARS

    export CC=$CB_CC
    export CXX=$CB_CXX

    if [[ "${PRJ_OPTS[ccache]}" == 1 && "${PRJ_OPTS[coverage]}" == 0 ]]; then
        local CCACHE
        cp_find_cmd CCACHE "ccache" 1

        if [ -n "CCACHE" ]; then
            CC="$CCACHE $CC"
            CXX="$CCACHE $CXX"
        fi
    fi
}

function cb_make_scan_cmd() {
    local CMD="$CB_CC ${CB_SCAN_ARGS[$CPKG_OS]}"

    if (($CB_CC_IS_CLANG)); then
        CMD+=" -w"
    fi

    mkdir -p $CB_EMPTY_DIR
    mkdir -p $CB_LOG_DIR

    local INCDIR

    for INCDIR in $@; do
        CMD="$CMD -I$INCDIR"
    done

    echo $CMD
}

function cb_autolink() {
    local HEADER=$1

    local RE
    local PC
    local PKG

    for RE in ${!CB_AUTOLINK[@]}; do
        if [[ $HEADER =~ $RE ]]; then
            local -a SPEC=(${CB_AUTOLINK[$RE]})
            PC=${SPEC[0]}

            if ((${#SPEC[@]} > 1)); then
                PKG=${SPEC[1]}
            else
                PKG="$(lp_pkg_from_header $HEADER)"

                if [ -z "$PKG" ]; then
                    PKG=$PC
                fi
            fi

            echo $PC $PKG ${CB_AUTOLINK_GROUP[$RE]}

            break
        fi
    done
}

function cb_install_pkg() {
    local TYPE=$1
    local TARGET=$2
    local FDEP=$3
    local PKG=$4

    if ! lp_is_pkg_installed $PKG; then
        local LABEL="Target $TYPE $TARGET depends on header '$FDEP'"
        LABEL+=", but it was not found on this system.\n\n"
        LABEL+="We suggest you install the following package:\n\n"
        LABEL+="  $PKG"

        if (($CB_YES)); then
            lp_install_packages $PKG
            NEED_RESCAN=1
            return 0
        elif cp_ask_for_install "$LABEL" $PKG; then
            NEED_RESCAN=1
            return 0
        else
            return 1
        fi
    fi

    return 0
}

function cb_autolink_install_pkg() {
    local TYPE=$1
    local TARGET=$2
    local FDEP=$3

    # Look in autolink rules
    local -a AUTOLINK=($(cb_autolink $FDEP))
    local PKG

    if ((${#AUTOLINK[@]} > 0)); then
        PKG=${AUTOLINK[1]}
        PRJ_AUTOLINK[${AUTOLINK[2]}]=1

        cb_install_pkg $TYPE $TARGET $FDEP $PKG
    else
        return 1
    fi
}

function cb_scan_target_files() {
    local TYPE=$1
    local TARGET=$2

    if (($CB_NO_SCAN)); then
        return
    fi

    local NEED_RESCAN=0

    . $(cb_get_target_file $TYPE $TARGET "SOURCES")
    . $(cb_get_target_file $TYPE $TARGET "HEADERS")
    . $(cb_get_target_file $TYPE $TARGET "LOCAL_HEADERS")

    local SCAN_CMD=$(cb_make_scan_cmd ${PRJ_HEADER_DIRS[@]})
    local KIND
    local -a FILES
    local DIR
    local -a FDEPS
    local FDEP
    local KEYFILE
    local -a CLEAN_EXPRS
    local -A RESOLVED_MAP
    local -A TARGET_MAP
    local -A SEEN_TDEPS
    local -a TDEPS
    local -A SEEN_PKGDEPS
    local -a PKGDEPS
    local -A SEEN_PCDEPS
    local -a PCDEPS
    local -a RUNTIME_PCDEPS
    local -A SEEN_RUNTIME_PCDEPS

    # Build map of this target files
    for KEYFILE in ${HEADERS[@]} ${LOCAL_HEADERS[@]} ${SOURCES[@]}; do
        TARGET_MAP[$KEYFILE]=1
    done

    TARGET_MAP["$PRJ_NAME/config.h"]=1
    TARGET_MAP["$PRJ_NAME/system_config.hpp"]=1

    # Build sed expression list to remove include directories
    # from dependencies
    for DIR in ${PRJ_HEADER_DIRS[@]}; do
        CLEAN_EXPRS+=("-e s,$DIR/,,g")
    done

    if (($CPKG_IS_PKGSRC)); then
        # Remove buildlink include dirs
        CLEAN_EXPRS+=("-e s,[^[:space:]]+/.buildlink/include/,,g")
    fi

    CLEAN_EXPRS+=("-e s,CBUILD_SOURCE:[[:space:]]([^[:space:]]+[[:space:]])?,,g")
    CLEAN_EXPRS+=("-e /^$/d")

    # Scan all of this target files
    for KIND in SOURCES HEADERS; do
        local AREF="${KIND}[@]"
        FILES=(${!AREF})

        if ((${#FILES} == 0)); then
            continue
        fi

        DIR=$(cb_get_target_dir $TYPE $TARGET $KIND)

        [ -d $DIR ] || cp_error "invalid directory: $DIR"
        cd $DIR

        # Get dependency info from compiler
        local ALLDEPS=$(
            $SCAN_CMD ${FILES[@]} 2>$CB_LOG_DIR/scan.log | \
            $CB_CPP -P | \
            cp_run_sed ${CLEAN_EXPRS[@]} | \
            tr -s ' ' | tr ' ' '\n' | \
            sort | uniq | xargs
        )

        [[ ! -s $CB_LOG_DIR/scan.log ]] || cat $CB_LOG_DIR/scan.log

        [[ $? == 0 ]] || cp_error "scan failed, aborting"

        local DEPLINE DEP FDEP PKG
        local IS_HEADER IS_SOURCE
        local SYS_AUTOLINK

        if [[ $KIND == "HEADERS" ]]; then
            IS_HEADER=1
            IS_SOURCE=0
        elif [[ $KIND == "SOURCES" ]]; then
            IS_HEADER=0
            IS_SOURCE=1
        fi

        # Read and process dependencies
        for FDEP in $ALLDEPS; do
            if ! [[ $FDEP =~ $CB_HDR_RE ]]; then
                # Ignore unrecognized headers
                continue
            fi

            local -a AUTOLINK=($(cb_autolink $FDEP))
            SYS_AUTOLINK=""

            if ((${#AUTOLINK[@]} > 0)); then
                if [[ ${AUTOLINK[1]} == "SYSTEM" ]]; then
                    SYS_AUTOLINK=1
                fi
            fi

            if [[ \
                "${STD_HEADERS[$FDEP]}" \
                || \
                "${TARGET_MAP[$FDEP]}" \
                || \
                "$SYS_AUTOLINK" \
            ]]; then
                # Ignore system/this target headers
                # Look for additional autolink rules
                if ((${#AUTOLINK[@]} > 0)); then
                    local PCDEP=(${AUTOLINK[0]})
                    PRJ_AUTOLINK[${AUTOLINK[2]}]=1

                    if [[ ! "${SEEN_PCDEPS[$PCDEP]}" ]]; then
                        PCDEPS+=($PCDEP)
                        SEEN_PCDEPS[$PCDEP]=1
                    fi
                fi

                continue
            fi

            # Find other LIB target owning this header
            local LIB_TARGET
            local FOUND=0

            for LIB_TARGET in ${LIB_TARGETS[@]}; do
                if [[ "${TARGET_HEADER_MAP[$FDEP]}" == $LIB_TARGET ]]; then
                    FOUND=$(($FOUND + 1))

                    # This target depends on one of this project libraries
                    if [[ ! "${SEEN_TDEPS[$LIB_TARGET]}" ]]; then
                        TDEPS+=($LIB_TARGET)
                        SEEN_TDEPS[$LIB_TARGET]=1

                        if [[ ! "${PLIB_TARGET_MAP[$LIB_TARGET]}" ]]; then
                            # Use library pkgconfig file ...
                            PCDEPS+=("lib$LIB_TARGET")
                            SEEN_PCDEPS["lib$LIB_TARGET"]=1

                            # ... and ignore everything obtained though it
                            # pkgconfigs first ...
                            for DEP in ${TARGET_PCDEP_MAP["LIB_$LIB_TARGET"]}; do
                                SEEN_PCDEPS[$DEP]=1
                            done

                            # ... packages next
                            for DEP in ${TARGET_PKGDEP_MAP["LIB_$LIB_TARGET"]}; do
                                SEEN_PKGDEPS[$DEP]=1
                            done
                        fi
                    fi
                fi
            done

            if [[ !$FOUND && -f $PRJ_GENINCDIR/$FDEP ]]; then
                # Ignore generated headers
                continue
            fi

            if ((!$FOUND)); then
                # No project target owns FDEP
                # look in (installed) system packages
                PKG=$(lp_pkg_from_header $FDEP)

                if [[ "$PKG" ]]; then
                    FOUND=$(($FOUND + 1))

                    # Ensure package is installed
                    cb_install_pkg $TYPE $TARGET $FDEP $PKG
                    cb_autolink_install_pkg $TYPE $TARGET $FDEP

                    local -a TPCDEPS

                    if [[ "$(lp_pkg_pkgconfigs $PKG)" ]]; then
                        # System package has pkg-config info
                        TPCDEPS=($(lp_pkg_pkgconfigs $PKG))
                    elif ((${#AUTOLINK[@]} > 0)); then
                        TPCDEPS+=(${AUTOLINK[0]})
                        PKG=${AUTOLINK[1]}
                        PRJ_AUTOLINK[${AUTOLINK[2]}]=1
                    fi

                    if [[ ! "${SEEN_PKGDEPS[$PKG]}" ]]; then
                        PKGDEPS+=($PKG)
                        SEEN_PKGDEPS[$PKG]=1

                        if (($IS_HEADER)); then
                            # Runtime package dependency
                            PRJ_RUNTIME_PKGS[$PKG]=1
                        fi
                    fi

                    local PCDEP

                    for PCDEP in ${TPCDEPS[@]}; do
                        if [[ ! "${SEEN_PCDEPS[$PCDEP]}" ]]; then
                            PCDEPS+=($PCDEP)
                            SEEN_PCDEPS[$PCDEP]=1
                        fi

                        if (($IS_HEADER)); then
                            if [[ ! "${SEEN_RUNTIME_PCDEPS[$PCDEP]}" ]]; then
                                # Runtime pkg-config dependency on a
                                # locally generated pkg-config file
                                RUNTIME_PCDEPS+=($PCDEP)
                                SEEN_RUNTIME_PCDEPS[$PCDEP]=1
                            fi
                        fi
                    done
                fi
            fi

            if ((!$NEED_RESCAN && !$FOUND)); then
                cp_warning \
                    "no target found for '$FDEP' ($TYPE $TARGET)"
                NOT_FOUND_MAP[$FDEP]=1
            fi
        done
    done

    cb_add_deps $TYPE $TARGET ${TDEPS[@]}
    cb_add_pkg_deps $TYPE $TARGET ${PKGDEPS[@]}
    cb_add_pc_deps $TYPE $TARGET ${PCDEPS[@]}
    cb_add_runtime_pc_deps $TYPE $TARGET ${RUNTIME_PCDEPS[@]}

    cb_save_target_list $TYPE $TARGET "TARGET_PCDEPS" ${PCDEPS[@]}

    return $NEED_RESCAN
}

function cb_scan_targets_files() {
    local TYPE
    local TARGET
    local AREF

    if (($CB_NO_SCAN)); then
        return
    fi

    for TYPE in $CB_SCAN_ORDER; do
        AREF="${TYPE}_TARGETS[@]"

        for TARGET in "${!AREF}"; do
            cp_msg "scanning $TYPE $TARGET"

            while ! cb_scan_target_files $TYPE $TARGET; do
                cb_update_caches
                cp_msg "re-scanning $TYPE $TARGET"
            done
        done
    done
}

function cb_get_pc_list() {
    local PCFLAG=$1
    local STRIP=$2
    local SKIP=$3
    shift 3

    local -a LIST
    local DEP
    local ITEMS
    local ITEM
    local -A SEEN_ITEMS

    local PCPATH=$PRJ_BUILDDIR/pkgconfig.private:$PRJ_BUILDDIR/pkgconfig

    if [[ -n "$PKG_CONFIG_PATH" ]]; then
        PCPATH+=":$PKG_CONFIG_PATH"
    fi

    local PKG_CONFIG_PATH=$PCPATH

    for DEP in $@; do
        ITEMS="$(lp_get_pkgconfig $DEP "$PCFLAG")"
        ITEMS=${ITEMS//$STRIP}
        ITEMS=${ITEMS## }
        ITEMS=${ITEMS%% }

        for ITEM in $ITEMS; do
            if [[ -n "$SKIP" && $ITEM == $SKIP ]]; then
                # Already configured by compiler
                continue
            fi

            if [[ ! "${SEEN_ITEMS[$ITEM]}" ]]; then
                LIST+=($ITEM)
                SEEN_ITEMS[$ITEM]=1
            fi
        done
    done

    echo ${LIST[@]}
}

function cb_configure_target_include() {
    local TYPE=$1
    local TARGET=$2

    set +e
    local -a TARGET_INC=(../../${TYPE_DIRS[$TYPE]}/$TARGET)

    local INC

    if [[ $TYPE == "TST" ]]; then
        INC=$PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/include
        [ -d $INC ] && TARGET_INC+=(../include)
    fi

    INC=$PRJ_SRCDIR/${TYPE_DIRS[INC]}/$TARGET
    [ -d $INC ] && TARGET_INC+=(../../${TYPE_DIRS[INC]}/$TARGET)

    INC=$PRJ_SRCDIR/${TYPE_DIRS[INC]}.private/$TARGET
    [ -d $INC ] && TARGET_INC+=(../../${TYPE_DIRS[INC]}.private/$TARGET)

    local DEP
    local TARGET_KEY="${TYPE}_${TARGET}"

    # Include directories of dependencies
    for DEP in ${TARGET_DEP_MAP[$TARGET_KEY]}; do
        INC=$PRJ_SRCDIR/${TYPE_DIRS[INC]}/$DEP
        [ -d $INC ] && TARGET_INC+=(../../${TYPE_DIRS[INC]}/$DEP)
    done

    local PCFLAGS=("--cflags-only-I" "-I" $CPKG_PREFIX/include)
    local PCS="${TARGET_PCDEP_MAP[$TARGET_KEY]}"

    # Include directories of pkg-config dependencies
    for INC in $(cb_get_pc_list ${PCFLAGS[@]} $PCS); do
        TARGET_INC+=($INC)
    done

    set -e

    cb_save_target_list $TYPE $TARGET "TARGET_INC" ${TARGET_INC[@]}
}

function cb_configure_target_link() {
    local TYPE=$1
    local TARGET=$2

    local TARGET_KEY="${TYPE}_${TARGET}"

    local PCFLAGS=("--libs-only-L" "-L" $CPKG_PREFIX/lib)
    local PCS="${TARGET_PCDEP_MAP[$TARGET_KEY]}"

    cb_save_target_list \
        $TYPE $TARGET "TARGET_LINK" \
        $(cb_get_pc_list ${PCFLAGS[@]} $PCS)

    local -A SEEN_MAP
    local -a LIBS
    local LIB
    local -a DEPS
    local DEP
    local -a PCDEPS
    local TARGET_KEY="${TYPE}_${TARGET}"

    # Dependencies
    for DEP in ${TARGET_DEP_MAP[$TARGET_KEY]}; do
        if [[ ! "${HLIB_TARGET_MAP[$DEP]}" ]]; then
            local DEPBN=$(cb_get_target_build_name "LIB" $DEP)
            LIBS+=($DEPBN)
            DEPS+=($DEPBN)
        fi
    done

    local PCS="${TARGET_PCDEP_MAP[$TARGET_KEY]}"

    for LIB in $(cb_get_pc_list "--libs-only-l" "-l" "" $PCS); do
        if [[ ! "${SEEN_MAP[$LIB]}" ]]; then
            LIBS+=($LIB)
            SEEN_MAP[$LIB]=1
        fi
    done

    local TCMALLOC=0
    local JEMALLOC=0

    ((${PRJ_OPTS[TCMalloc]})) && TCMALLOC=1
    ((${PRJ_OPTS[jemalloc]})) && JEMALLOC=1

    if (($TCMALLOC && $JEMALLOC)); then
        cp_error "use TCMalloc or jemalloc, not both"
    fi

    (($TCMALLOC)) && LIBS+=("tcmalloc")

    if (($JEMALLOC)); then
        local PKG=${CB_JEMALLOC_PKGS[$CPKG_OS]}

        if [ -n "$PKG" ]; then
            LIBS+=("jemalloc")

            if ! lp_is_pkg_installed $PKG; then
                lp_install_packages $PKG
            fi
        fi
    fi

    cb_save_target_list \
        $TYPE $TARGET "TARGET_LIBS" \
        ${LIBS[@]}

    cb_save_target_list \
        $TYPE $TARGET "TARGET_DEPS" \
        ${DEPS[@]}
}

function cb_configure_target_pkgconfig() {
    local TYPE=$1
    local TARGET=$2

    local TARGET_KEY="${TYPE}_${TARGET}"
    local -a PCS
    local -A SEEN_PCS
    local PC

    for PC in ${TARGET_RUNTIME_PCDEP_MAP[$TARGET_KEY]}; do
        if ((${PRJ_LOCAL_PKGCONFIGS[$PC]})); then
            if [[ ! "${SEEN_PCS[$PC]}" ]]; then
                PCS+=($PC)
                SEEN_PCS[$PC]=1
            fi
        fi
    done

    cb_save_target_var $TYPE $TARGET "+TVARS" "TARGET_PC_CFLAGS" \
        "$(cb_get_pc_list "--cflags" "" $CPKG_PREFIX/include ${PCS[@]})"

    cb_save_target_var $TYPE $TARGET "+TVARS" "TARGET_PC_LIBS" \
        "$(cb_get_pc_list "--libs" "" $CPKG_PREFIX/lib ${PCS[@]})"
}

function cb_configure_target() {
    local TYPE=$1
    local TARGET=$2

    cb_configure_target_include $TYPE $TARGET
    cb_configure_target_link $TYPE $TARGET

    cb_save_target_var $TYPE $TARGET "TVARS" "TARGET" $TARGET
    cb_save_target_var $TYPE $TARGET "+TVARS" "TARGET_OUTPUT_NAME" \
        $(cb_get_target_output_name $TYPE $TARGET)
    cb_save_target_var $TYPE $TARGET "+TVARS" "TARGET_BUILD_NAME" \
        $(cb_get_target_build_name $TYPE $TARGET)

    if [[ -e $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$TARGET/.cbuild_noinst ]]; then
        cb_save_target_var $TYPE $TARGET "+TVARS" "TARGET_NOINST" 1
    fi

    if [[ \
        $TYPE == "PLUG" \
        && \
        -f $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$TARGET/.plug_class \
    ]]; then
        local PLUG_CLASS="$(head -n 1 $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$TARGET/.plug_class)"

        cb_save_target_var $TYPE $TARGET "+TVARS" "PLUG_CLASS" $PLUG_CLASS
        PLUG_CLASSES[$PLUG_CLASS]=1
    fi

    cb_configure_target_pkgconfig $TYPE $TARGET

    CPKG_TMPL_PRE=($CB_STATE_DIR/PRJ/CCVARS)
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/OPTS)
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/PLIBS)
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/LOCAL_PKGCONFIGS)
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "HEADERS"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "SOURCES"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TVARS"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TARGET_INC"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TARGET_LINK"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TARGET_LIBS"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TARGET_DEPS"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TARGET_PCDEPS"))

    local OLD_TMPL_VARS="$CPKG_TMPL_VARS"
    CPKG_TMPL_VARS+=" $CB_TMPL_VARS"

    if [[ ! "${HLIB_TARGET_MAP[$TARGET]}" ]]; then
        cp_process_templates \
            $SHAREDIR/templates/build-systems/CMake/$TYPE \
            $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$TARGET
    fi

    if [ -d $SHAREDIR/templates/cbuild/$TYPE ]; then
        cp_process_templates \
        $SHAREDIR/templates/cbuild/$TYPE
    fi

    CPKG_TMPL_VARS="$OLD_TMPL_VARS"
}

function cb_sort_targets() {
    local TYPE=$1

    # Process dependency histogram to build in correct order
    local AREF="${TYPE}_TARGETS[@]"
    local -a HIST
    local HKEY

    for HKEY in ${!AREF}; do
        HIST+=("${TARGET_DEP_HIST[$HKEY]},$HKEY")
    done

    local HISTLINES="$(cp_join "\n" ${HIST[@]})"
    local -a ORDERED=($(echo "$HISTLINES" | sort -t , -r | xargs))
    ORDERED=(${ORDERED[@]//[[:digit:]]*,})

    echo ${ORDERED[@]}
}

function cb_configure_targets() {
    local TYPE
    local TARGET
    local AREF

    CPKG_TMPL_PRE=($CB_STATE_DIR/PRJ/CCVARS)
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/HEADER_DIRS)

    # Create map of project options
    cp_save_hash "PRJ_OPTS" $CB_STATE_DIR/PRJ/OPTS
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/OPTS)

    # Don't overwrite these file when not scanning
    cp_save_list \
        "PRJ_NOCOV" \
        $CB_STATE_DIR/PRJ/NOCOV \
        ${PRJ_NOCOV[@]}
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/NOCOV)

    # Create map of system packages used
    cp_save_hash "PRJ_PKGS" $CB_STATE_DIR/PRJ/PKGS
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/PKGS)

    # Create map of system packages used at runtime
    cp_save_hash "PRJ_RUNTIME_PKGS" $CB_STATE_DIR/PRJ/RUNTIME_PKGS
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/RUNTIME_PKGS)

    # Create map of needed autolink helpers
    cp_save_hash "PRJ_AUTOLINK" $CB_STATE_DIR/PRJ/AUTOLINK
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/AUTOLINK)

    # Create map of target types
    cp_save_hash "PRJ_HAS" $CB_STATE_DIR/PRJ/HAS
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/HAS)

    # Create map of header-only libraries
    cp_save_hash "HLIB_TARGET_MAP" $CB_STATE_DIR/PRJ/HLIBS
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/HLIBS)

    # Create map of private libraries
    cp_save_hash "PLIB_TARGET_MAP" $CB_STATE_DIR/PRJ/PLIBS
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/PLIBS)

    # Create map of binaries not to install
    cp_save_hash "NOINST_TARGET_MAP" $CB_STATE_DIR/PRJ/NOINST
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/NOINST)

    # Create map of plugin classes
    cp_save_hash "PLUG_CLASSES" $CB_STATE_DIR/PRJ/PLUG_CLASSES
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/PLUG_CLASSES)

    local TYPE

    for TYPE in $CB_SCAN_ORDER; do
        cp_save_list \
            "PRJ_${TYPE}S" \
            $CB_STATE_DIR/PRJ/${TYPE}S \
            $(cb_sort_targets $TYPE)

        CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/${TYPE}S)
    done

    cp_save_list \
        "PRJ_BINS_ONLY" \
        $CB_STATE_DIR/PRJ/BINS_ONLY \
        ${BIN_ONLY_TARGETS[@]}

    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/BINS_ONLY)

    cp_save_list \
        "PRJ_SVCS" \
        $CB_STATE_DIR/PRJ/SVCS \
        ${SVC_TARGETS[@]}

    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/SVCS)

    cp_save_hash "PRJ_MANPAGES" $CB_STATE_DIR/PRJ/MANPAGES
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/MANPAGES)

    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/SVCS)

    local OLD_TMPL_VARS="$CPKG_TMPL_VARS"
    CPKG_TMPL_VARS+=" $CB_TMPL_VARS"

    if ((!$CB_NO_SCAN)); then
        if [ -d $SHAREDIR/templates/cbuild/pkg-config/$CPKG_TYPE ]; then
            cp_process_templates \
                $SHAREDIR/templates/cbuild/pkg-config/$CPKG_TYPE
        fi

        for PCFILE in $(cp_find_rel $PRJ_BUILDDIR/pkgconfig.private); do
            PCFILE=$(basename $PCFILE .pc)
            PRJ_LOCAL_PKGCONFIGS[$PCFILE]=1
        done

        # Create map of locally generated pkg-config file
        cp_save_hash "PRJ_LOCAL_PKGCONFIGS" $CB_STATE_DIR/PRJ/LOCAL_PKGCONFIGS
        CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/LOCAL_PKGCONFIGS)
    fi

    if [ -d $SHAREDIR/templates/cbuild/packaging/$CPKG_TYPE ]; then
        cp_process_templates \
            $SHAREDIR/templates/cbuild/packaging/$CPKG_TYPE

        PKG_ROOTDIR=$PRJ_BUILDDIR/packaging
        PKG_STAGEDIR=$PRJ_BUILDDIR/packaging
        lp_process_package_files
    fi

    cd $TOPDIR

    cp_process_templates \
        $SHAREDIR/templates/build-systems/CMake/PRJ \
        $PRJ_SRCDIR

    cp_process_templates $SHAREDIR/templates/cbuild/PRJ_MK

    CPKG_TMPL_VARS="$OLD_TMPL_VARS"

    for TYPE in $CB_SCAN_ORDER; do
        AREF="${TYPE}_TARGETS[@]"

        for TARGET in "${!AREF}"; do
            PRJ_TARGET=$TARGET
            cb_configure_target $TYPE $TARGET
        done
    done
}

function cb_configure_tests() {
    [[ -d $PRJ_BATSDIR ]] || return 0

    local BAT
    local BATS=$(find $PRJ_BATSDIR -mindepth 1 -maxdepth 1)

    if [[ -n "BATS" ]]; then
        PRJ_BINTSTDIR=$PRJ_TSTDIR/000_compiled
        PRJ_BATSTSTDIR=$PRJ_TSTDIR/001_meta
    fi

    [[ -d $PRJ_BATSTSTDIR ]] || mkdir -p $PRJ_BATSTSTDIR
    cd $PRJ_BATSTSTDIR

    find . -type l -exec rm {} \;

    local BNAME

    for BAT in $BATS; do
        BNAME=$(basename $BAT)
        cp_msg "adding Bats test $BNAME"
        ln -s $BAT $BNAME
    done
}

function cb_run_generator() {
    ((!$PKG_UPDATE)) || return 0

    cp_find_cmd CB_GEN "cmake"
    cd $PRJ_BUILDDIR

    local -a GENOPTS=(
        "-DCMAKE_INSTALL_PREFIX=$CPKG_PREFIX"
    )

    if [[ -n "$CMAKE_GEN" && $CMAKE_GEN != "Unix Makefiles" ]]; then
        GENOPTS+=("-G" "$CMAKE_GEN")
    fi

    $CB_GEN "${GENOPTS[@]}" $PRJ_SRCDIR

    # Clean and remove those pesky cmake_progress_* from makefiles
    local -a MAKEFILES=($(
        find . \( \
            -name Makefile\* \
            -o \
            -name build.make \
        \)
    ))

    cp_reinplace "
        /(cmake_progress_|progress\.make|Built target)/d
        s,Building CXX .*\.dir/(.*)\.o,  [CXX] \1,
        s,Building C .*\.dir/(.*)\.o,  [CC ] \1,
        s,Linking .*/(bin|lib/plugins|lib|t)/(.*),  [LD ] \1/\2,
    " ${MAKEFILES[@]}
}

function cb_configure() {
    cb_check_conf

    export CB_PKGSRC_BUILD=0

    if [[ -f $TOPDIR/../.extract_done ]]; then
        # We're under pkgsrc build
        CB_PKGSRC_BUILD=1
    fi

    mkdir -p $PRJ_BUILDDIR/man

    ACTION="configure"
    cb_find_cpus
    cb_update_caches
    cb_configure_compiler
    cb_configure_tests
    cb_scan
    cb_scan_targets_files
    cb_configure_targets
    cb_run_generator
    STATUS=0

    if (($CB_PKGSRC_BUILD)); then
        # Avoid warnings about leftover files
        cp_clear_home
    fi
}
