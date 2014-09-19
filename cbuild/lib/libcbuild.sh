set -e

# Check BASH version
if [ "${BASH_VERSINFO[0]}" -ne 4 ]; then
    echo "Bash version 4 or greater is needed (you have: $BASH_VERSION)"
    exit 1
fi

# Check cpkg-config is available
if ! which cpkg-config >/dev/null; then
    echo "cpkg-config not found, please install cpkg"
    exit 1
fi

ACTION=""
STATUS=1

function handle_trap() {
    local SIG="$1"

    local MSG
    local FUNC

    if [[ $SIG == "INT" || $SIG == "TERM" ]]; then
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

    eval "$FUNC $MSG"

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
declare -A TARGET_TYPE_MAP
declare -A TARGET_HEADER_MAP
declare -A TARGET_DEP_MAP
declare -A TARGET_PKGDEP_MAP
declare -A TARGET_PCDEP_MAP
declare -A TARGET_DEP_HIST
declare -A HLIB_TARGET_MAP
declare -A PLIB_TARGET_MAP
declare -A NOT_FOUND_MAP
declare -A STD_HEADERS
declare -a PRJ_HEADER_DIRS
declare -A PRJ_MANPAGES
declare -A PRJ_OPTS
declare -a PRJ_CFLAGS
declare -a PRJ_CXXFLAGS
declare -a PRJ_LFLAGS
declare -A PRJ_PKGS
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
    [SHAREDIR]=0
)

# Set defaults
PRJ_NAME=$(basename $TOPDIR)
PKG_NAME=${PRJ_NAME//_/-}
PKG_AUTHOR="Lazy Programmer <eat@joes.com>"
PRJ_SRCDIR=$TOPDIR/sources
PRJ_BUILDDIR=$TOPDIR/build
PRJ_BATSDIR=$TOPDIR/bats
PRJ_HAS_BATS=0
PRJ_ETCDIR=$TOPDIR/etc
PRJ_SHAREDIR=$TOPDIR/share
PRJ_BINDIR=$PRJ_BUILDDIR/bin
PRJ_TSTDIR=$PRJ_BUILDDIR/t
PRJ_BINTSTDIR=""
PRJ_BATSTSTDIR=""
PRJ_LIBDIR=$PRJ_BUILDDIR/lib
PRJ_PLUGDIR=$PRJ_BUILDDIR/lib/plugins
PRJ_GENINCDIR=$PRJ_BUILDDIR/${TYPE_DIRS[INC]}.generated
PRJ_INCDIR=$PRJ_BUILDDIR/${TYPE_DIRS[INC]}
PRJ_PRIVINCDIR=$PRJ_BUILDDIR/${TYPE_DIRS[INC]}.private
PRJ_TARGET="none"
PRJ_DEFPREFIX="${PRJ_NAME^^}_"
PRJ_USER=root
PRJ_GROUP=$PRJ_USER

if [[ -f $CBUILD_CONF ]]; then
    . $CBUILD_CONF
    [[ -z "$PKG_VER" ]] && PKG_VER=1.0
    (($PKG_REV)) || PKG_REV=1

    for LIB in ${PRJ_PRIVATE_LIBS[@]}; do
        PLIB_TARGET_MAP[$LIB]=1
    done
fi

. $(cpkg-config -L)

PROJECT_VARS="PRJ_NAME PKG_AUTHOR"
PROJECT_VARS+=" PKG_SHORTDESC PKG_LONGDESC PRJ_TARGET PRJ_DEFPREFIX"
PROJECT_DIRS="PRJ_SRCDIR PRJ_BUILDDIR PRJ_BATSDIR"
PROJECT_DIRS+=" PRJ_BINDIR PRJ_TSTDIR PRJ_BINTSTDIR PRJ_BATSTSTDIR"
PROJECT_DIRS+=" PRJ_LIBDIR PRJ_PLUGDIR"
PROJECT_DIRS+=" PRJ_GENINCDIR PRJ_INCDIR PRJ_PRIVINCDIR"
PROJECT_VARS+=" PRJ_USER PRJ_GROUP PRJ_HAS_BATS"
CB_TMPL_VARS="TOPDIR $PROJECT_VARS $PROJECT_DIRS"
export $CB_TMPL_VARS

# Regular expressions used to find a target source files
CB_SRC_RE=".*\.(c|cc|cpp|cxx)"
CB_HDR_RE=".*\.(h|hh|hpp|hxx|inl|ipp)"

CB_STATE_DIR=$(pwd)/.cbuild

export CB_CC_IS_GCC=0
export CB_CC_IS_CLANG=0

# Default compiler commands
declare -A CB_CPPS=(
    [Linux]=cpp
    [Darwin]=cpp
)
declare -A CB_CCS=(
    [Linux]=gcc
    [Darwin]=clang
)
declare -A CB_CC_VERSIONS=(
    [Linux]=4.8
    [Darwin]=
)
declare -A CB_CXXS=(
    [Linux]=g++
    [Darwin]=clang++
)
declare -A CB_GCOVS=(
    [Linux]=gcov
    [Darwin]=gcov
)

CB_EMPTY_DIR=$CB_STATE_DIR/empty-dir

CB_COMMON_SCAN_ARGS="-x c++ -M -MG -MT CBUILD_SOURCE"
CB_COMMON_SCAN_ARGS+=" -nostdinc -nostdinc++"
CB_COMMON_SCAN_ARGS+=" -D${CPKG_PF^^} -D${CPKG_OS^^}"
CB_COMMON_SCAN_ARGS+=" -I$CB_EMPTY_DIR"

declare -A CB_SCAN_ARGS=(
    [Linux]="$CB_COMMON_SCAN_ARGS"
    [Darwin]="$CB_COMMON_SCAN_ARGS"
)

CB_SCAN_ORDER="LIB PLUG BIN TST"

declare -a CB_GEN_FLAGS
declare -a CB_LFLAGS
declare -a CB_BIN_LFLAGS
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

export CB_CPUS=1

# Load autolink definitions
declare -A CB_AUTOLINK

function cb_check_conf() {
    if [[ -f $CBUILD_CONF ]]; then
        cp_ensure_vars_are_set $PROJECT_VARS
    fi
}

function cb_load_autolink() {
    local FILE=$1

    [ -f $FILE ] || return 0

    local -A AUTOLINK
    . $FILE

    local RE

    for RE in ${!AUTOLINK[@]}; do
        CB_AUTOLINK[$RE]=${AUTOLINK[$RE]}
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
        CPUS=$(grep "^cpu cores" /proc/cpuinfo | head -n 1 | cut -d : -f 2)
        CPUS=${CPUS## }
        CPUS=${CPUS%% }
    elif [[ $CPKG_OS == "Darwin" ]]; then
        CPUS=$(/usr/sbin/sysctl machdep.cpu.core_count | cut -d : -f 2)
        CPUS=${CPUS## }
        CPUS=${CPUS%% }
    fi

    CB_CPUS=$CPUS
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

    cb_save_target_list $TYPE $NAME "SOURCES"

    local NOT_A_SERVICE=1
    local SOURCE SOURCEFILE

    if [ $TYPE = "BIN" ]; then
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
        if [ \
            ! -d $PRJ_SRCDIR/$TYPE_DIR \
            -o \
            ! -d $PRJ_SRCDIR/${TYPE_DIRS[INC]} \
        ]; then
            return 0
        fi
    else
        # Other targets must have sources
        if [ ! -d $PRJ_SRCDIR/$TYPE_DIR ]; then
            return 0
        fi
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

    if [ -d $PRJ_SHAREDIR ]; then
        PRJ_HAS["SHAREDIR"]=1
    fi

    for TYPE in $CB_SCAN_ORDER; do
        cb_scan_targets $TYPE
    done
}

function cb_find_std_headers() {
    local KEYWORD
    local CXX_INCDIR

    if (($CB_CC_IS_GCC)); then
        KEYWORD="install: "
    elif (($CB_CC_IS_CLANG)); then
        KEYWORD="libraries: ="
    fi

    local INCDIRS=$(
        $CB_CPP -print-search-dirs 2>&1 | \
        grep "^$KEYWORD"
    )

    INCDIRS=${INCDIRS##$KEYWORD}
    INCDIRS=${INCDIRS//:/ }

    if (($CB_CC_IS_CLANG)); then
        CXX_INCDIR=${INCDIRS%%/clang*}
        CXX_INCDIR+="/c++/v1"
    fi

    local INCDIR
    local INC

    for INCDIR in $INCDIRS; do
        INCDIR=${INCDIR%/}
        INCDIR+="/include"

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

    if (($CB_CC_IS_GCC)); then
        CXX_INCDIR=$(
            $CB_CC -v 2>&1 | \
            grep "^Configured with: "
        )
        CXX_INCDIR=${CXX_INCDIR##*--with-gxx-include-dir=}
        CXX_INCDIR=${CXX_INCDIR%% *}
        CXX_INCDIR=${CXX_INCDIR%/}
    fi

    if [ -d $CXX_INCDIR ]; then
        for INC in $(cp_find_rel $CXX_INCDIR); do
            STD_HEADERS[$INC]=1
        done
    fi
}

function cb_configure_compiler_flags() {
    set +e
    [[ ${PRJ_OPTS[std]} ]] && CB_CXXFLAGS+=("-std=${PRJ_OPTS[std]}")

    if (($CB_CC_IS_CLANG)); then
        CB_CXXFLAGS+=("-stdlib=libc++")
        CB_CXXFLAGS+=("-Qunused-arguments" "-fcolor-diagnostics")
        CB_CFLAGS+=("-Qunused-arguments" "-fcolor-diagnostics")
    fi

    if (($CB_CC_IS_GCC)); then
        CB_GEN_FLAGS+=("-g3" "-ggdb3" "-pthread")
    else
        CB_GEN_FLAGS+=("-g")
    fi

    CB_GEN_FLAGS+=("-pipe" "-Wall")

    [[ ${PRJ_OPTS[auto_export]} ]] || CB_GEN_FLAGS+=("-fvisibility=hidden")
    [[ ${PRJ_OPTS[ide]} ]] && CB_GEN_FLAGS+=("-fmessage-length=0")

    CB_CXXFLAGS+=("-ftemplate-depth=256")

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
        CB_GEN_FLAGS+=("-O0")
    fi

    if [[ $CPKG_BIN_ARCH == "x86_64" ]]; then
        CB_GEN_FLAGS+=(
            "-march=native"
        )
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
    local VER=${CB_CC_VERSIONS[$CPKG_OS]}

    if [[ "$VER" ]]; then
        local VPRE

        case $CPKG_OS in
            Linux)
            VPRE="-"
            ;;
        esac

        VER=${VPRE}${VER}
    fi

    local DEF_CPP=${CPP:-${CB_CPPS[$CPKG_OS]}$VER}
    local DEF_CC=${CC:-${CB_CCS[$CPKG_OS]}$VER}
    local DEF_CXX=${CXX:-${CB_CXXS[$CPKG_OS]}$VER}
    local DEF_GCOV=${GCOV:-${CB_GCOVS[$CPKG_OS]}$VER}

    cp_find_cmd CB_CPP $DEF_CPP
    cp_find_cmd CB_CC $DEF_CC
    cp_find_cmd CB_CXX $DEF_CXX

    if ((${PRJ_OPTS[coverage]})); then
        cp_find_cmd CB_GCOV $DEF_GCOV
    fi

    [[ $CB_CC =~ gcc ]] && CB_CC_IS_GCC=1
    [[ $CB_CC =~ clang ]] && CB_CC_IS_CLANG=1

    cb_find_std_headers
    cb_configure_compiler_flags

    local CCVARS=$CB_STATE_DIR/PRJ/CCVARS
    cp_save_list "CB_GEN_FLAGS" $CCVARS ${CB_GEN_FLAGS[@]}
    cp_save_list "CB_LFLAGS" "+$CCVARS" ${CB_LFLAGS[@]}
    cp_save_list "CB_BIN_LFLAGS" "+$CCVARS" ${CB_BIN_LFLAGS[@]}
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

    [ ! -d $CB_EMPTY_DIR ] && mkdir -p $CB_EMPTY_DIR

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

            if [[ "${CPKG_HEADER_MAP[$HEADER]}" ]]; then
                PKG="${CPKG_HEADER_MAP[$HEADER]}"
            elif ((${#SPEC[@]} > 1)); then
                PKG=${SPEC[1]}
            else
                PKG=$PC
            fi

            echo $PC $PKG

            break
        fi
    done
}

function cb_install_pkg() {
    local TYPE=$1
    local TARGET=$2
    local FDEP=$3
    local PKG=$4

    if [[ ! "${CPKG_PKG_MAP[$PKG]}" ]]; then
        local LABEL="Target $TYPE $TARGET depends on header '$FDEP'"
        LABEL+=", but it was not found on this system.\n\n"
        LABEL+="We suggest you install the following package:\n\n"
        LABEL+="  $PKG"

        if cp_ask_for_install "$LABEL" $PKG; then
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
    local -A TARGET_MAP
    local -A SEEN_TDEPS
    local -a TDEPS
    local -A SEEN_PKGDEPS
    local -a PKGDEPS
    local -A SEEN_PCDEPS
    local -a PCDEPS

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

    CLEAN_EXPRS+=("-e s,CBUILD_SOURCE:[[:space:]],,g")

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
        local DEPLINES=$(
            $SCAN_CMD ${FILES[@]} 2>&1 | \
            $CB_CPP -P | \
            sed ${CLEAN_EXPRS[@]}
        )

        [[ $? == 0 ]] || cp_error "scan failed, aborting"

        local DEPLINE
        local PKG
        local DEP

        # Read and clean dependencies
        for DEPLINE in "$DEPLINES"; do
            read -a FDEPS <<<$DEPLINE

            if ((!${#FDEPS[@]})); then
                # No dependencies
                continue
            fi

            # First element is target file (source or header)
            KEYFILE=${FDEPS[0]}
            # Rest is dependencies
            FDEPS=(${FDEPS[@]:1})

            for FDEP in ${FDEPS[@]}; do
                if ! [[ $FDEP =~ $CB_HDR_RE ]]; then
                    # Ignore unrecognized headers
                    continue
                fi

                if [[ "${NOT_FOUND_MAP[$FDEP]}" ]]; then
                    # Ignore already unknown headers
                    continue
                fi

                if [[ "${STD_HEADERS[$FDEP]}" || "${TARGET_MAP[$FDEP]}" ]]; then
                    # Ignore system/this target headers
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
                        fi
                    fi
                done

                if [[ !$FOUND && $FDEP =~ ^${PRJ_NAME}/ ]]; then
                    # Ignore generated headers
                    continue
                fi

                if ((!$FOUND)); then
                    # No project target owns FDEP
                    # look in (installed) system packages
                    if [[ "${CPKG_HEADER_MAP[$FDEP]}" ]]; then
                        FOUND=$(($FOUND + 1))
                        PKG=${CPKG_HEADER_MAP[$FDEP]}

                        # Ensure package is installed
                        cb_install_pkg $TYPE $TARGET $FDEP $PKG
                        cb_autolink_install_pkg $TYPE $TARGET $FDEP

                        local -a TPCDEPS

                        if [[ "${CPKG_PKGCONFIG_MAP[$PKG]}" ]]; then
                            # System package has pkg-config info
                            TPCDEPS=(${CPKG_PKGCONFIG_MAP[$PKG]})
                        else
                            # Look in autolink rules
                            local -a AUTOLINK=($(cb_autolink $FDEP))

                            if ((${#AUTOLINK[@]} > 0)); then
                                TPCDEPS+=(${AUTOLINK[0]})
                                PKG=${AUTOLINK[1]}
                            fi
                        fi

                        if [[ ! "${SEEN_PKGDEPS[$PKG]}" ]]; then
                            PKGDEPS+=($PKG)
                            SEEN_PKGDEPS[$PKG]=1
                        fi

                        local PCDEP

                        for PCDEP in ${TPCDEPS[@]}; do
                            if [[ ! "${SEEN_PCDEPS[$PCDEP]}" ]]; then
                                PCDEPS+=($PCDEP)
                                SEEN_PCDEPS[$PCDEP]=1
                            fi
                        done
                    fi
                fi

                if ((!$FOUND)); then
                    local HINT

                    if [[ $FDEP =~ / ]]; then
                        # Include with library name prefix
                        HINT=$(dirname $FDEP)
                        HINT=${HINT%%/*}
                    else
                        # Remove any extension
                        HINT=${FDEP%%\.*}
                    fi

                    local -a MATCHES=($(lp_find_c_lib $HINT))

                    if ((${#MATCHES} > 0)); then
                        local LABEL="Target $TYPE $TARGET depends"
                        LABEL+=" on header '$FDEP'"
                        LABEL+=", but it was not found on this system.\n\n"
                        LABEL+="The following package(s) may provide it:"

                        cp_choose "$LABEL" "Install a package" ${MATCHES[@]}

                        if [ -n "$CPKG_CHOICE" ]; then
                            lp_install_packages $CPKG_CHOICE
                            NEED_RESCAN=1
                        fi
                    fi
                fi

                if ((!$NEED_RESCAN && !$FOUND)); then
                    cp_warning \
                        "no target found for '$FDEP' ($TYPE $TARGET $KEYFILE)"
                    NOT_FOUND_MAP[$FDEP]=1
                fi
            done
        done
    done

    cb_add_deps $TYPE $TARGET ${TDEPS[@]}
    cb_add_pkg_deps $TYPE $TARGET ${PKGDEPS[@]}
    cb_add_pc_deps $TYPE $TARGET ${PCDEPS[@]}

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
    local TARGET=$1
    local PCFLAG=$2
    local STRIP=$3
    local SKIP=$4

    local -a LIST
    local DEP
    local ITEMS
    local ITEM

    local PKG_CONFIG_PATH=$PRJ_BUILDDIR/pkgconfig.private
    local TARGET_KEY="${TYPE}_${TARGET}"

    for DEP in ${TARGET_PCDEP_MAP[$TARGET_KEY]}; do
        ITEMS="$(lp_get_pkgconfig $DEP "$PCFLAG")"
        ITEMS=${ITEMS//$STRIP}
        ITEMS=${ITEMS## }
        ITEMS=${ITEMS%% }

        for ITEM in $ITEMS; do
            if [[ "$SKIP" && $ITEM == $SKIP ]]; then
                # Already configured by compiler
                continue
            fi

            LIST+=($ITEM)
        done
    done

    echo ${LIST[@]}
}

function cb_configure_target_include() {
    local TYPE=$1
    local TARGET=$2

    set +e
    local -a TARGET_INC=(
        $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$TARGET
    )

    local INC

    INC=$PRJ_SRCDIR/${TYPE_DIRS[INC]}/$TARGET
    [ -d $INC ] && TARGET_INC+=($INC)

    INC=$PRJ_SRCDIR/${TYPE_DIRS[INC]}.private/$TARGET
    [ -d $INC ] && TARGET_INC+=($INC)

    INC=$PRJ_BUILDDIR/${TYPE_DIRS[INC]}.generated
    [ -d $INC ] && TARGET_INC+=($INC)

    local DEP
    local TARGET_KEY="${TYPE}_${TARGET}"

    # Include directories of dependencies
    for DEP in ${TARGET_DEP_MAP[$TARGET_KEY]}; do
        INC=$PRJ_SRCDIR/${TYPE_DIRS[INC]}/$DEP
        [ -d $INC ] && TARGET_INC+=($INC)
    done

    local PCFLAGS=("--cflags-only-I" "-I" $CPKG_PREFIX/include)

    # Include directories of pkg-config dependencies
    for INC in $(cb_get_pc_list $TARGET ${PCFLAGS[@]}); do
        TARGET_INC+=($INC)
    done

    set -e

    cb_save_target_list $TYPE $TARGET "TARGET_INC" ${TARGET_INC[@]}
}

function cb_configure_target_link() {
    local TYPE=$1
    local TARGET=$2

    local PCFLAGS=("--libs-only-L" "-L" $CPKG_PREFIX/lib)

    cb_save_target_list \
        $TYPE $TARGET "TARGET_LINK" \
        $(cb_get_pc_list $TARGET ${PCFLAGS[@]})

    local -a LIBS
    local LIB
    local -a DEPS
    local DEP
    local TARGET_KEY="${TYPE}_${TARGET}"

    # Dependencies
    for DEP in ${TARGET_DEP_MAP[$TARGET_KEY]}; do
        if [[ "${HLIB_TARGET_MAP[$DEP]}" ]]; then
            continue
        fi

        local DEPBN=$(cb_get_target_build_name "LIB" $DEP)
        LIBS+=($DEPBN)
        DEPS+=($DEPBN)
    done

    for LIB in $(cb_get_pc_list $TARGET "--libs-only-l" "-l"); do
        LIBS+=($LIB)
    done

    cb_save_target_list \
        $TYPE $TARGET "TARGET_LIBS" \
        ${LIBS[@]}

    cb_save_target_list \
        $TYPE $TARGET "TARGET_DEPS" \
        ${DEPS[@]}
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

    CPKG_TMPL_PRE=($CB_STATE_DIR/PRJ/CCVARS)
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/OPTS)
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/PLIBS)
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "HEADERS"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "SOURCES"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TVARS"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TARGET_INC"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TARGET_LINK"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TARGET_LIBS"))
    CPKG_TMPL_PRE+=($(cb_get_target_file $TYPE $TARGET "TARGET_DEPS"))

    local OLD_TMPL_VARS="$CPKG_TMPL_VARS"
    CPKG_TMPL_VARS+=" $CB_TMPL_VARS"

    if ((!$CB_NO_SCAN)); then
        if [[ ! "${HLIB_TARGET_MAP[$TARGET]}" ]]; then
            cp_process_templates \
                $SHAREDIR/templates/build-systems/CMake/$TYPE \
                $PRJ_SRCDIR/${TYPE_DIRS[$TYPE]}/$TARGET
        fi

        if [ -d $SHAREDIR/templates/cbuild/$TYPE ]; then
            cp_process_templates \
                $SHAREDIR/templates/cbuild/$TYPE
        fi
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

    # Create map of target types
    cp_save_hash "PRJ_HAS" $CB_STATE_DIR/PRJ/HAS
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/HAS)

    # Create map of header-only libraries
    cp_save_hash "HLIB_TARGET_MAP" $CB_STATE_DIR/PRJ/HLIBS
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/HLIBS)

    # Create map of private libraries
    cp_save_hash "PLIB_TARGET_MAP" $CB_STATE_DIR/PRJ/PLIBS
    CPKG_TMPL_PRE+=($CB_STATE_DIR/PRJ/PLIBS)

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

    cp_process_templates $SHAREDIR/templates/cbuild/PRJ

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
    else
        PRJ_BINTSTDIR=$PRJ_TSTDIR
        PRJ_BATSTSTDIR=$PRJ_TSTDIR
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
    cp_find_cmd CB_GEN "cmake"
    cd $PRJ_BUILDDIR
    $CB_GEN -DCMAKE_INSTALL_PREFIX=$CPKG_PREFIX $PRJ_SRCDIR

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
}
