#!/bin/bash
#

# All variables used in the script should be prefixed with "SE_"
# Some of these are changed while parsing getopts.
SE_XCOMP_FILE=unset
SE_DO_BUILD=unset
SE_ERLANG_SOURCE_FILE=unset
SE_SMP_ENABLED=unset
SE_RELEASE_DIR=stripped_release

# Internal functions
usage()
{
    cat<<EOF
Usage: [options]

Available options:
    -a <xcomp file>    Analyze xcomp file. If set no other options are needed.
    -b <xcomp file>    Build Erlang with a xcomp file (not supported yet)
    -e <Erlang src>    Set the Erlang source tarball used for building
    -d                 Optional, keeps the temp build directory.
                       Useful for debugging the script.
    -s                 Enable Erlang SMP. If not set beam.smp will be removed
                       Even if it was built. If enabled the non-smp beam will 
                       be removed. 
EOF
exit
}

analyse_xcomp()
{
    if [ `grep "CFLAGS=" $SE_XCOMP_FILE | grep -c "\-DSMALL_MEMORY"` == 1 ]
    then
        echo "GCC optimisation flag -DSMALL_MEMORY enabled"
    else
        echo "GCC optimisation flag -DSMALL_MEMORY disabled"
        echo "    Recommended for limited memory systems."
        echo "    You can enable it by editing the 'CFLAGS=' entry in"
        echo "    ${SE_XCOMP_FILE}"
    fi
    SE_O_LEVEL=`grep "CFLAGS=" $SE_XCOMP_FILE | grep -o "\ -O. " `
    if [ `grep "CFLAGS=" $SE_XCOMP_FILE | grep -c "\-O. "` != 0 ]
    then
        echo "GCC optimisation flag${SE_O_LEVEL} enabled"
        if [ `echo ${SE_O_LEVEL} | grep -c "s"` == 0 ]
        then
            echo "    -0s is recommended when optimising for limited disk size"
        fi
    else
        echo "GCC optimisation flag -Ox disabled"
        echo "    -Os is recommended to optimise for small disk size."
        echo "    You can enable it by editing the 'CFLAGS=' entry in"
        echo "    ${SE_XCOMP_FILE}"
    fi
}
# End of internal functions

# Begin script execution
# 1. Parse options
if ( ! getopts ":a:" opt); then
    usage
    exit 1
fi

while getopts ":a:b:e:sd" Option
do
    case $Option in
        a ) 
            SE_XCOMP_FILE=${OPTARG}
            analyse_xcomp
            exit 0
            ;;
        b )
            SE_XCOMP_FILE=${OPTARG}
            SE_DO_BUILD=yes
            ;;
        e )
            SE_ERLANG_SOURCE_FILE=${OPTARG}
            SE_DO_BUILD=yes
            ;;
        s )
            SE_SMP_ENABLED=true
            ;;
        d )
            SE_DEBUG_ENABLED=true
            ;;
        * ) usage
            exit 1
            ;;
    esac
done

# 2. Create a directory for building and configuration of Erlang release and unpack source.
if [ "$SE_DO_BUILD" == yes ]
then
    if [ "$SE_ERLANG_SOURCE_FILE" == unset ]
    then
        echo "A build requires an Erlang source tarball, set it with -e <file>"
        echo "Download one with 'wget http://www.erlang.org/download/otp_src_R14B04.tar.gz'"
        exit 1
    fi
    SE_TIMESTAMP=`date +%F_%H%M%S`
    SE_BUILD_DIR=stripped_erlang_$SE_TIMESTAMP
    echo "Making build dir ${SE_BUILD_DIR}"
    mkdir $SE_BUILD_DIR
    echo "Unpacking source and moving into dir.."
    tar xfz $SE_ERLANG_SOURCE_FILE -C $SE_BUILD_DIR
fi

# 3. Enter directory and build the source.
SE_OTP_SOURCE_DIR_NAME=`tar -tf ${SE_ERLANG_SOURCE_FILE} | grep -o '^[^/]\+' | sort -u`
cd $SE_BUILD_DIR
mkdir $SE_RELEASE_DIR
SE_BUILD_DIR_ABS=$PWD
SE_OTP_SOURCE_DIR_ABS=$SE_BUILD_DIR_ABS/$SE_OTP_SOURCE_DIR_NAME
cd $SE_OTP_SOURCE_DIR_ABS

export ERL_TOP=$SE_OTP_SOURCE_DIR_ABS
./configure
make
make RELEASE_ROOT=$SE_BUILD_DIR_ABS/$SE_RELEASE_DIR release

# 4. Strip beams
erl -eval "beam_lib:strip_release('$SE_BUILD_DIR_ABS/$SE_RELEASE_DIR')" -s init stop > /dev/null
cd $SE_BUILD_DIR_ABS/$SE_RELEASE_DIR

# 5. Strip binaries (using correct tool chain)
#TODO: use toolchain specified in xcomp.conf or from CLI option
strip erts-*/bin/*

# 6. Remove crap (src, include, doc etc.)
echo "Removing unnecessary files and directories"
rm -rf usr/
rm -rf misc/
for SE_DIR in erts* lib/*; do
    rm -rf ${SE_DIR}/src
    rm -rf ${SE_DIR}/include
    rm -rf ${SE_DIR}/doc
    rm -rf ${SE_DIR}/man
    rm -rf ${SE_DIR}/examples
    rm -rf ${SE_DIR}/emacs
    rm -rf ${SE_DIR}/c_src
done
rm -rf erts-*/lib/

rm erts-*/bin/dialyzer
rm erts-*/bin/erlc
rm erts-*/bin/typer
rm erts-*/bin/ct_run

if [ "$SE_SMP_ENABLED" == yes ]
then
    echo "SMP enabled, removing non-SMP BEAM binary"
    rm erts-*/bin/beam
else
    echo "SMP disabled, removing SMP BEAM binary"
    rm erts-*/bin/beam.smp
fi

# 7. Compress .ez archives (without priv!)
cd lib
SE_LIBS=$(ls)

for SE_APP in $SE_LIBS; do
    if [ "${SE_APP##*.}" == "ez" ]; then
        echo "Skipping $SE_APP, already compressed"
    else
        echo "Compressing $SE_APP"
        # Skip priv directories, they need to exist on disk
        zip -0 -q -r ${SE_APP}.zip $SE_APP -x $SE_APP/priv/\*
        mv ${SE_APP}.zip ${SE_APP}.ez
        if [ ! -d $SE_APP/priv ]; then
            rm -f -r $SE_APP
        else
            mv ${SE_APP}/priv ${SE_APP}_priv
            rm -f -r $SE_APP
            mkdir -p $SE_APP
            mv ${SE_APP}_priv ${SE_APP}/priv
        fi
    fi
done
cd ..
# 8. A script file; 'Install', was generated by the release making. Editing out some things from it:
#    - delete everything that is copied from erts-*/bin
#    - delete run_test link
sed -i 's/cp -p $ERL_ROOT\/erts-.*\/bin\/erl .//' Install
sed -i 's/cp -p $ERL_ROOT\/erts-.*\/bin\/erlc .//' Install
sed -i 's/cp -p $ERL_ROOT\/erts-.*\/bin\/dialyzer .//' Install
sed -i 's/cp -p $ERL_ROOT\/erts-.*\/bin\/typer .//' Install
sed -i 's/cp -p $ERL_ROOT\/erts-.*\/bin\/ct_run .//' Install
sed -i 's/cp -p $ERL_ROOT\/erts-.*\/bin\/escript .//' Install
sed -i 's/ln -s ct_run run_test//' Install

# 9. Create installation archive
cd ../..
SE_TARBALL_PREFIX=minimal_erlang_$SE_OTP_SOURCE_DIR_NAME_$SE_TIMESTAMP
mkdir $SE_TARBALL_PREFIX
cp -r $SE_BUILD_DIR/$SE_RELEASE_DIR $SE_TARBALL_PREFIX/
echo "

Installation:

1. Unpack archive.
2. ./Install -minimal

" >> $SE_TARBALL_PREFIX/README

tar czf $SE_TARBALL_PREFIX.tar.gz $SE_TARBALL_PREFIX

if [ "$SE_DEBUG_ENABLED" != yes ]
then
    rm -rf $SE_BUILD_DIR
fi

echo "Done. Check README in $SE_TARBALL_PREFIX folder/tarball."

# TODO (on target system):
# 1. Unpack archive at preffered location (this will be $ERL_ROOT)
# 2. Run $ERL_ROOT/Install -minimal 

