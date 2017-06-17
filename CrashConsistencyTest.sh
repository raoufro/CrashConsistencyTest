#!/bin/bash

trap "_cleanup 'CrashConsistencyTest cancelled!'; exit 1" 2 15

. config || {
cat << EOF
	There is no config file in current directory.
	See config.sample as an exmaple.
EOF
	exit 1
}

. tests_helper/config_generator
. tests_helper/xfstests_consistency
. tests_helper/dbtests_consistency
. utils/log

DEVMAP_PART="/dev/mapper/${DEVMAP_LOG_WRITES}"
TOOLS_DIR="${LOCALS}/usr/local/sbin"

XFSTESTS_DIR="${LOCALS}/var/lib/xfstests"
DBTESTS_DIR="${LOCALS}/var/lib/dbtests"

CUR_DATE=`date +%y%m%d_%H%M%S`
XFSTESTS_RESULT_DIR=$RESULT_DIR/xfstests
CCTESTS_RESULT_DIR=$RESULT_DIR/consistency_tests

EXCLUDE_FILE=
TESTS_RESULT_DIR=
TESTS_LOG=
TESTS_FSCK_LOG=

BLKSIZE=
COW_LOOP_DEV=

##############################
# Clean up before exit
#
# $1 - Log Content
##############################
_cleanup()
{
	_log $1
	umount $CCTESTS_MNT &> /dev/null
	umount $LOGDEV &> /dev/null
	umount $REPLAYDEV &> /dev/null
	dmsetup remove $DEVMAP_LOG_WRITES &> /dev/null
	# Return to root of tests in case of interruption
	popd &> /dev/null
	cp $EXCLUDE_FILE $TESTS_RESULT_DIR
}

##############################
# Do some cleanup operations after fail
#
# $1 - Log Content
##############################
_fail()
{
	_log $1
	umount $CCTESTS_MNT &> /dev/null
	dmsetup remove $DEVMAP_LOG_WRITES &> /dev/null
}

##############################
# Inform the successful operations
#
# $1 - Log Content
##############################
_inform()
{
	_log $1
}

##############################
# Run consistency tests
#
# $1 single/all/db/single_upto
# $2 the name of xfstests for single mode
##############################
consistency()
{
	[ -z $LOGDEV ] && { _fail "Must set LOGDEV and REPLAYDEV."; exit 1; }
	[ -z $REPLAYDEV ] &&  { _fail "Must set LOGDEV and REPLAYDEV."; exit 1; }
	[ -z $DEVMAP_LOG_WRITES ] &&  { _fail "Must set DEVMAP_LOG_WRITES."; exit 1; }
	[ ! -d $LOCALS ] && { _fail "Must create LOCALS directory."; exit 1; }


	EXCLUDE_FILE=excludes/$CCTESTS_EXCLUDE
	TESTS_RESULT_DIR=$CCTESTS_RESULT_DIR/$1-$CUR_DATE
	TESTS_LOG=$TESTS_RESULT_DIR/log
	TESTS_FSCK_LOG=$TESTS_RESULT_DIR/fsck_log
	TESTS_CKPT_LOG=$TESTS_RESULT_DIR/ckpt_log

	# Prepare the Environment
	mkdir -p ${TESTS_RESULT_DIR}
	[ -d $CCTESTS_MNT ] || mkdir -p $CCTESTS_MNT

	BLKSIZE=$(blockdev --getsz $REPLAYDEV)
	gen_fsck_config

	case $1 in
		single)
			gen_xfstests_config consistency_tests
			gen_exclude
			consistency_single $2 0
			;;
		single_upto)
			gen_xfstests_config consistency_tests
			gen_exclude
			consistency_single $2 1
			;;
		all)
			gen_xfstests_config consistency_tests
			gen_exclude
			consistency_tests
			;;
		db)
			gen_dbtests_config
			consistency_db
			;;
		*)
			print_help
			;;
	esac

	_cleanup "Cleaning up after consistency test."
}

##############################
# Run xfstests
#
# $1 single/all
# $2 the name of xfstests for single mode (e.g. generic/009)
##############################
xfstests()
{
	local aTest
	[ ! -d $LOCALS ] &&  { _fail "Must create LOCALS directory."; exit 1; }

	EXCLUDE_FILE=excludes/$XFSTESTS_EXCLUDE
	TESTS_RESULT_DIR=$XFSTESTS_RESULT_DIR/$1-$CUR_DATE
	TESTS_LOG=$TESTS_RESULT_DIR/log

	# Prepare the Test Environment
	mkdir -p $TESTS_RESULT_DIR
	[ -d $TEST_DIR ] || mkdir -p $TEST_DIR
	[ -d $SCRATCH_MNT ] || mkdir -p $SCRATCH_MNT
	gen_xfstests_config xfstests
	gen_exclude
	${TOOLS_DIR}/mkfs.${FSTYPE} ${TEST_DEV} &> /dev/null

	case $1 in
		single)
			pushd ${XFSTESTS_DIR} > /dev/null
			./check -E ./${XFSTESTS_EXCLUDE} -s ${FSTYPE}_xfstests $2
			popd > /dev/null
			;;
		all)
			pushd ${XFSTESTS_DIR} > /dev/null
			./check -E ./${XFSTESTS_EXCLUDE} -s ${FSTYPE}_xfstests
			popd > /dev/null
			;;
		*)
			print_help
			;;
	esac

	_cleanup "Cleaning up after xfstests."
}

setup_env()
{
	mkdir -p $LOCALS
	pushd src
	
	tar xzvf ${F2FS_TOOLS}.tar.gz
	pushd ${F2FS_TOOLS}
	./autogen.sh
	./configure
	make
	make install DESTDIR="$LOCALS"
	popd

	tar xzvf e2fsprogs-v1.43.4.tar.gz
	pushd e2fsprogs-v1.43.4
	mkdir build
	pushd build
	../configure
	make
	make install DESTDIR="$LOCALS/usr/local"
	popd
	popd

	tar xzvf xfstests-f2fs.tar.gz
	pushd xfstests-f2fs
	make
	make install DESTDIR="$LOCALS"
	popd

	tar xzvf log-writes-v0.1.tar.gz
	pushd log-writes-v0.1 
	make
	install -m 755 replay-log $LOCALS/usr/local/sbin
	popd

	tar xzvf dbtests.tar.gz
	cp -pr dbtests $LOCALS/var/lib

	popd

	ldconfig ${LOCALS}/usr/local/lib

	grep "123456-fsgqa" /etc/passwd > /dev/null || useradd 123456-fsgqa
	grep "fsgqa" /etc/passwd > /dev/null || useradd fsgqa
}

clean()
{
	pushd src
	
	[ -d $F2FS_TOOLS ] &&
	{
		pushd $F2FS_TOOLS
		make clean
		popd
	}

	[ -d e2fsprogs-v1.43.4 ] && 
	{
		pushd e2fsprogs-v1.43.4 
		make clean
		popd
	}



	[ -d xfstests-f2fs ] &&
	{
		pushd xfstests-f2fs
		make clean
		popd
	}

	[ -d log-writes-v0.1 ] && 
	{
		pushd log-writes-v0.1 
		make clean
		popd
	}

	popd
	rm -rf $LOCALS
	rm -rf $RESULT_DIR
}

print_help() 
{ 
cat << EOF
Usage: CrashConsistencyTest [help] 
	setup_env: set up the environment for test - build and install tools
	clean: clean the src directories 
	xfstests:
		all - run all tests related to FSTYPE
		single test - run a single test (mention the complete name of test)
	consistency: check the consistency of f2fs for each BIOs in
		all - all generic tests of xfstests
		single test -  a single test
		single_upto test - a single test from an entry
		db - a sysbench benchmark
EOF
} 

case $1 in 
	setup_env)
		setup_env
		;;
	clean)
		clean
		;;
	xfstests)
		shift 1
		xfstests $*
		;;
	consistency)
		shift 1
		consistency $*
		;;
#	mkfs_ckpt_test)
#		shift 1
#		ckpt_test $*
#		;;
	*)
		print_help
		;;
esac
