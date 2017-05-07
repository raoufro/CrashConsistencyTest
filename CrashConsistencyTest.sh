#!/bin/bash

trap "_cleanup 'CrashConsistencyTest cancelled!'; exit 1" 2 15

. utils/log
. config || {
cat << EOF
	There is no config file in current directory.
	See config.sample as an exmaple.
EOF
	exit 1
}


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
	losetup -d $COW_LOOP_DEV &> /dev/null
	rm -f cow-dev &> /dev/null
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


_test()
{
	mount -t ${FSTYPE} ${DEVMAP_PART} ${CCTESTS_MNT}
	cp -arv /etc/bashrc ${CCTESTS_MNT}
	sync
	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark fsync
	md5sum ${CCTESTS_MNT}/bashrc
	umount ${CCTESTS_MNT}

	dmsetup remove log
		
	${LOCALS}/usr/local/sbin/replay-log --log ${LOGDEV} --replay ${REPLAYDEV} --end-mark fsync \
		|| _fail "Failed to replay ${LOGDEV} on ${REPLAYDEV}-${LINENO}"
	mount -t ${FSTYPE} ${REPLAYDEV} ${CCTESTS_MNT}
	md5sum ${CCTESTS_MNT}/bashrc
	umount ${CCTESTS_MNT}
}

##############################
# Generate the configuration file of xfstests
#
# $1 - The type of tests
##############################
gen_xfstests_config()
{
	case $1 in
		xfstests)
			echo -e "[${FSTYPE}_xfstests]\n"\
			"TEST_DEV=${TEST_DEV}\n"\
			"TEST_DIR=${TEST_DIR}\n"\
			"SCRATCH_DEV=${SCRATCH_DEV}\n"\
			"SCRATCH_MNT=${SCRATCH_MNT}\n"\
			"FSTYP=$FSTYPE\n"\
			"MOUNT_OPTIONS=\"$MOUNT_OPTS\"\n"\
			"RESULT_BASE=${RESULT_DIR}/xfstests/${CUR_DATE}\n"\
			> $XFSTESTS_DIR/"local.config"
			;;
		consistency_tests)
			echo -e "[${FSTYPE}_consistency]\n"\
			"TEST_DEV=$DEVMAP_PART\n"\
			"TEST_DIR=$CCTESTS_MNT\n"\
			"FSTYP=$FSTYPE\n"\
			"MOUNT_OPTIONS=\"$MOUNT_OPTS\"\n"\
			"RESULT_BASE=${RESULT_DIR}/consistency_tests/${CUR_DATE}"\
			> $XFSTESTS_DIR/"local.config"
			;;
	esac
}

#ckpt_test()
#{
#	[ -z $LOGDEV ] && exit "Must set LOGDEV and REPLAYDEV"
#	[ -z $REPLAYDEV ] && exit "Must set LOGDEV and REPLAYDEV"
#	[ -z $DEVMAP_LOG_WRITES ] && exit "Must set DEVMAP_LOG_WRITES"
#	[ ! -d $LOCALS ] && exit "Must create LOCALS directory"

#	gen_xfstests_config consistency_tests
#	apply_test $1

#	echo "***** Replaying mkfs *****"
#	ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark mkfs_end)
#	echo "mkfs_end entry is $ENTRY."
#	${TOOLS_DIR}/replay-log --log $LOGDEV --replay $REPLAYDEV --end-mark mkfs_end || _fail "mkfs replay failed-$LINENO" 
#	echo "CKPT after mkfs_end"
#       ${TOOLS_DIR}/dump.f2fs $REPLAYDEV | grep --binary-files=text CKPT
#	echo

#	echo -e "Replaying test #$1 ...\n"
#	START_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_start)
#	END_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_end)
#	echo "START_ENTRY is $START_ENTRY"
#	echo "END_ENTRY is $END_ENTRY"
#	echo

#	sleep 5

#	let ENTRY=START_ENTRY
#	while [ $ENTRY -lt $END_ENTRY ]; do
#		echo "***** Entry #$ENTRY *****"
#		${TOOLS_DIR}/replay-log --limit 1 --log $LOGDEV --replay $REPLAYDEV \
#			--start $ENTRY || _fail "replay failed"
#		echo "CKPT after replay"
#		${TOOLS_DIR}/dump.f2fs $REPLAYDEV | grep --binary-files=text CKPT
#		${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV > /dev/null 2>&1
#		mount -t ${FSTYPE} $REPLAYDEV $CCTESTS_MNT || _fail "mount failed at entry $ENTRY"
#		umount $CCTESTS_MNT
#		echo "CKPT after mount/umount"
#		${TOOLS_DIR}/dump.f2fs $REPLAYDEV | grep --binary-files=text CKPT
#		${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV > /dev/null 2>&1
#		let ENTRY+=1
#		echo
#	done
#}

##############################
# Run a single generic test of xfstests and
# log its writes by using log-writes dm target
#
# $1 - The test file of xfstests
##############################
apply_test()
{
	local aTest
	aTest=$1

	# Create log-writes
	TABLE="0 ${BLKSIZE} log-writes ${REPLAYDEV} ${LOGDEV}"
	dmsetup create ${DEVMAP_LOG_WRITES} --table "${TABLE}" > /dev/null ||\
	{ _fail "Failed to setup log-writes target."; return 1; }

	# Mark mkfs
	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark mkfs_start ||\
	{ _fail "Failed to mark the start of mkfs."; return 1; }

	${TOOLS_DIR}/mkfs.${FSTYPE} ${DEVMAP_PART} > /dev/null ||\
	{ _fail "Failed to mkfs ${DEVMAP_PART}."; return 1; }

	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark mkfs_end ||\
	{ _fail "Failed to mark the end of mkfs."; return 1; }

	# Apply the test and mark it
	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark ${aTest}_start ||\
	{ _fail "Failed to mark the start of test."; return 1; }
	pushd ${XFSTESTS_DIR} > /dev/null
	./check -E ./${CCTESTS_EXCLUDE} -s ${FSTYPE}_consistency ${aTest}
	popd > /dev/null
	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark ${aTest}_end ||\
	{ _fail "Failed to mark the end of test."; return 1; }

	# Remove log-writes
	dmsetup remove ${DEVMAP_LOG_WRITES} ||\
	{ _fail "Failed to remove ${DEVMAP_LOG_WRITES} dm target."; return 1; }
}

##############################
# Replay the log of a test
#
# $1 - The test file of xfstests
##############################
apply_consistency_test()
{
	local aTest
	aTest=$1

	echo "Replaying mkfs ..."
	ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark mkfs_end)
	${TOOLS_DIR}/replay-log --log $LOGDEV --replay $REPLAYDEV --end-mark mkfs_end ||\
	{ _fail "The replay of mkfs failed."; return 1; }

	START_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark ${aTest}_start)
	END_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark ${aTest}_end)

	echo "Replaying test $aTest ..."
	echo "START_ENTRY is $START_ENTRY"
	echo "END_ENTRY is $END_ENTRY"

	${TOOLS_DIR}/replay-log -v --log $LOGDEV --replay $REPLAYDEV --start-mark ${aTest}_start\
		--fsck "$FSCK_SCRIPT $XFSTESTS_NUM" --check 1 ||\
		{ _fail "The replay of xfstests failed."; return 1; }
}

##############################
# Run a single generic test of xfstests and
# verify the consistency of file system during the test
#
# $1 - The generic test number of xfstests
##############################
consistency_single()
{
	local aTest
	aTest=generic/$1

	apply_test $aTest
	RET=$?

	if [ $RET -ne 0 ]; then
		echo "$aTest" >> $CCTESTS_RESULT_DIR/failed_tests
		_inform "[FAIL] Running $aTest failed."
	else
		apply_consistency_test $aTest
		RET=$?
		if [ $RET -ne 0 ]; then
			echo "$aTest" >> $CCTESTS_RESULT_DIR/failed_tests
			_inform "[FAIL] Running $aTest failed."
		else
			echo "$aTest" >> $CCTESTS_RESULT_DIR/successful_tests
			_inform "Running $aTest was successful."
			echo
		fi
	fi
}

##############################
# Run all the generic tests of xfstests and
# verify the consistency of file system during the tests
##############################
consistency_tests()
{
	local aTest
	for aTest in $(ls $XFSTESTS_DIR/tests/generic | egrep "^[0-9]*$" | sort -n); do
		consistency_single $aTest
	done
}

##############################
# Run consistency tests
#
# $1 single/all
# $2 the name of xfstests for single mode
##############################
consistency()
{
	[ -z $LOGDEV ] && (_fail "Must set LOGDEV and REPLAYDEV."; exit 1)
	[ -z $REPLAYDEV ] && (_fail "Must set LOGDEV and REPLAYDEV."; exit 1)
	[ -z $DEVMAP_LOG_WRITES ] && (_fail "Must set DEVMAP_LOG_WRITES."; exit 1)
	[ ! -d $LOCALS ] && (_fail "Must create LOCALS directory."; exit 1)

	mkdir -p $CCTESTS_RESULT_DIR
	gen_xfstests_config consistency_tests
	gen_exclude
	# export variables to be accessible to the fsck_script
	export EXCLUDE_FILE=${PWD}/excludes/$CCTESTS_EXCLUDE
	export TESTS_RESULT_DIR=$CCTESTS_RESULT_DIR
	export TESTS_LOG=$CCTESTS_RESULT_DIR/log


	# Set up snapshot-origin target for $REPLAYDEV
	export SNAPSHOTBASE="replay-base"
	export SNAPSHOTBASE_DEV="/dev/mapper/$SNAPSHOTBASE"
	BLKSIZE=$(blockdev --getsz $REPLAYDEV)
	export ORIGIN_TABLE="0 $BLKSIZE snapshot-origin $REPLAYDEV"

	# Create 1TB sparse file as COW device
	dd if=/dev/zero of=cow-dev bs=1M count=1 seek=1048576 2> /dev/null
	export COW_LOOP_DEV=$(losetup -f --show cow-dev)

	# Set up snapshot target for
	export SNAPSHOTCOW="replay-cow"
	export SNAPSHOTCOW_DEV="/dev/mapper/$SNAPSHOTCOW"
	export COW_TABLE="0 $BLKSIZE snapshot /dev/mapper/$SNAPSHOTBASE $COW_LOOP_DEV N 8"
	export TARGET=/dev/mapper/$SNAPSHOTCOW

	case $1 in
		single)
			consistency_single $2
			;;
		all)
			consistency_tests
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
	[ ! -d $LOCALS ] &&  (_fail "Must create LOCALS directory."; exit 1)

	${TOOLS_DIR}/mkfs.${FSTYPE} ${LOGDEV} &> /dev/null
	${TOOLS_DIR}/mkfs.${FSTYPE} ${REPLAYDEV} &> /dev/null

	mkdir -p $XFSTESTS_RESULT_DIR
	gen_xfstests_config xfstests
	gen_exclude

	export EXCLUDE_FILE=${PWD}/excludes/$XFSTESTS_EXCLUDE
	export TESTS_RESULT_DIR=$XFSTESTS_RESULT_DIR
	export TESTS_LOG=$XFSTESTS_RESULT_DIR/log	# TODO - Log operations

	case $1 in
		single)
			pushd ${XFSTESTS_DIR}
			./check -E ./${XFSTESTS_EXCLUDE} -s ${FSTYPE}_xfstests $2
			popd
			;;
		all)
			pushd ${XFSTESTS_DIR}
			./check -E ./${XFSTESTS_EXCLUDE} -s ${FSTYPE}_xfstests
			popd
			;;
		*)
			print_help
			;;
	esac

	_cleanup "Cleaning up after xfstests."
}

##############################
# copy the files containg the excluded tests to xfstests' root directory
##############################
gen_exclude()
{
	cp excludes/{$XFSTESTS_EXCLUDE,$CCTESTS_EXCLUDE} $XFSTESTS_DIR
}

setup_env()
{
	mkdir -p $LOCALS
	pushd src
	
	tar xzvf f2fs-tools-v1.8.0.tar.gz
	pushd f2fs-tools-v1.8.0
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

	popd

	ldconfig $LIB_DIR
	mkdir -p /mnt/xfstests/f2fs_SCRATCH
	mkdir -p /mnt/xfstests/f2fs_TEST
	mkdir -p /mnt/crash_consistency/f2fs

	grep "123456-fsgqa" /etc/passwd > /dev/null || useradd 123456-fsgqa
	grep "fsgqa" /etc/passwd > /dev/null || useradd fsgqa
}

clean()
{
	pushd src
	
	[[ -d f2fs-tools-v1.8.0 ]] && 
	{
		pushd f2fs-tools-v1.8.0 
		make clean
		popd
	}


	[[ -d xfstests-f2fs ]] &&
	{
		pushd xfstests-f2fs
		make clean
		popd
	}

	[[ -d log-writes-v0.1 ]] && 
	{
		pushd log-writes-v0.1 
		make clean
		popd
	}
	
	popd
	rm -rf $LOCALS
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
EOF
} 

export BLKSIZE=$(blockdev --getsz $REPLAYDEV)
export DEVMAP_PART="/dev/mapper/${DEVMAP_LOG_WRITES}"
export TOOLS_DIR="${LOCALS}/usr/local/sbin"
export LIB_DIR="${LOCALS}/usr/local/lib"
export XFSTESTS_DIR="${LOCALS}/var/lib/xfstests"
CUR_DATE=`date +%y%m%d_%H%M%S`
XFSTESTS_RESULT_DIR=$RESULT_DIR/xfstests/$CUR_DATE
CCTESTS_RESULT_DIR=$RESULT_DIR/consistency_tests/$CUR_DATE

[ -d $CCTESTS_MNT ] || mkdir -p $CCTESTS_MNT
[ -d $TEST_DIR ] || mkdir -p $TEST_DIR
[ -d $SCRATCH_MNT ] || mkdir -p $SCRATCH_MNT

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
