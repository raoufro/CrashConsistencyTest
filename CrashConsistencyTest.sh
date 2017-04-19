#!/bin/bash -x

. config || {
cat << EOF
	There is no config file in current directory.
	See config.sample as an exmaple.
EOF
	exit 1
}

trap "_fail 'CrashConsistencyTest cancelled!'; exit 1" 2 15

_fail()
{
	echo $1
	umount $CCTESTS_MNT &> /dev/null
	dmsetup remove $DEVMAP_LOG_WRITES &> /dev/null
	losetup -d $COW_LOOP_DEV &> /dev/null
	rm -f cow-dev &> /dev/null
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

#
# $1 - The base directoy for the results of xfstests' local.config
#
xfstests_config_gen()
{
	CUR_DATE='`date +%y%m%d_%H%M%S`'
	case $1 in
		xfstests)
			echo -e "[${FSTYPE}_xfstests]\n"\
			"TEST_DEV=${TEST_DEV}\n"\
			"TEST_DIR=${TEST_DIR}\n"\
			"SCRATCH_DEV=${SCRATCH_DEV}\n"\
			"SCRATCH_MNT=${SCRATCH_MNT}\n"\
			"FSTYP=$FSTYPE\n"\
			"MOUNT_OPTTION=\"$MOUNT_OPTS\"\n"\
			"RESULT_BASE=${RESULT_DIR}/xfstests/${CUR_DATE}\n"\
			> $XFSTESTS_DIR/"local.config"
			;;
		consistency_tests)
			echo -e "[${FSTYPE}_consistency]\n"\
			"TEST_DEV=$DEVMAP_PART\n"\
			"TEST_DIR=$CCTESTS_MNT\n"\
			"FSTYP=$FSTYPE\n"\
			"MOUNT_OPTTION=\"$MOUNT_OPTS\"\n"\
			"RESULT_BASE=${RESULT_DIR}/consistency_tests"\
			> $XFSTESTS_DIR/"local.config"
			;;
	esac
}
#
# $1 - The number of xfstests' generic test
#
apply_test()
{
	# Create log-writes
	TABLE="0 ${BLKSIZE} log-writes ${REPLAYDEV} ${LOGDEV}"
	dmsetup create ${DEVMAP_LOG_WRITES} --table "${TABLE}" > /dev/null || _fail "Failed to setup log-writes target-${LINENO}"

	# Mark mkfs
	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark mkfs_start || _fail "Failed to mark the end of mkfs-${LINENO}"
	${TOOLS_DIR}/mkfs.${FSTYPE} ${DEVMAP_PART} > /dev/null || _fail "Failed to mkfs ${DEVMAP_PART}-${LINENO}"
	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark mkfs_end || _fail "Failed to mark the end of mkfs-${LINENO}"

	# Apply the test and mark it
	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark $1_start
	pushd ${XFSTESTS_DIR} > /dev/null
	./check -E ./${CCTESTS_EXCLUDE} -s ${FSTYPE}_consistency $1
	popd > /dev/null
	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark $1_end


	# Remove log-writes
	dmsetup remove ${DEVMAP_LOG_WRITES}
}

#
# Deprecated
#
old_apply_consistency_test()
{
	echo "Replaying mkfs ..."
	ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark mkfs_end)
	${TOOLS_DIR}/replay-log --log $LOGDEV --replay $REPLAYDEV --limit $ENTRY || _fail "mkfs replay failed-$LINENO" 

	START_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_start)
	END_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_end)

	
	echo -e "Replaying test #$1 ...\n\n"
	echo "START_ENTRY is $START_ENTRY"
	echo "END_ENTRY is $END_ENTRY"
	
	let ENTRY=START_ENTRY
	if [[ $DEBUG=="ON" ]]; then
		while [ $ENTRY -lt $END_ENTRY ]; do
			echo " Entry #$ENTRY "
			${TOOLS_DIR}/replay-log --limit 1 --log $LOGDEV --replay $REPLAYDEV \
				--start $ENTRY || _fail "replay failed"
			${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV \
				|| _fail "fsck failed at entry $ENTRY"
			mount -t ${FSTYPE} $REPLAYDEV $CCTESTS_MNT || _fail "mount failed at entry $ENTRY"
			umount $CCTESTS_MNT
			${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV \
				|| _fail "fsck failed after umount at entry $ENTRY"
			let ENTRY+=1
		done
	else
		while [ $ENTRY -lt $END_ENTRY ]; do
			echo " Entry #$ENTRY "
			${TOOLS_DIR}/replay-log --limit 1 --log $LOGDEV --replay $REPLAYDEV \
				--start $ENTRY || _fail "replay failed"
			${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV > /dev/null 2>&1 \
				|| _fail "fsck failed at entry $ENTRY"
			mount -t ${FSTYPE} $REPLAYDEV $CCTESTS_MNT || _fail "mount failed at entry $ENTRY"
			umount $CCTESTS_MNT
			${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV > /dev/null 2>&1 \
				|| _fail "fsck failed after umount at entry $ENTRY"
			let ENTRY+=1
		done
	fi
}

apply_consistency_test()
{
	echo "Replaying mkfs ..."
	ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark mkfs_end)
	${TOOLS_DIR}/replay-log --log $LOGDEV --replay $REPLAYDEV --end-mark mkfs_end || _fail "mkfs replay failed-$LINENO" 

	START_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_start)
	END_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_end)

	echo -e "Replaying test #$1 ...\n\n"
	echo "START_ENTRY is $START_ENTRY"
	echo "END_ENTRY is $END_ENTRY"

	${TOOLS_DIR}/replay-log -v --log $LOGDEV --replay $REPLAYDEV --start-mark $1_start\
		--fsck "$FSCK_SCRIPT" --check 1 || _fail "replay failed"

}

consistency_single()
{
	apply_test $1
	apply_consistency_test $1
}

consistency_tests()
{
	for aTest in $(ls $XFSTESTS_DIR/tests/generic | egrep "^[0-9]*$" | sort -n); do
		apply_test $aTest
		apply_consistency_test $aTest
	done
}

ckpt_test()
{
	[ -z $LOGDEV ] && exit "Must set LOGDEV and REPLAYDEV"
	[ -z $REPLAYDEV ] && exit "Must set LOGDEV and REPLAYDEV"
	[ -z $DEVMAP_LOG_WRITES ] && exit "Must set DEVMAP_LOG_WRITES"
	[ ! -d $LOCALS ] && exit "Must create LOCALS directory"

	xfstests_config_gen consistency_tests
	apply_test $1

	echo "***** Replaying mkfs *****"
	ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark mkfs_end)
	echo "mkfs_end entry is $ENTRY."
	${TOOLS_DIR}/replay-log --log $LOGDEV --replay $REPLAYDEV --end-mark mkfs_end || _fail "mkfs replay failed-$LINENO" 
	echo "CKPT after mkfs_end"
        ${TOOLS_DIR}/dump.f2fs $REPLAYDEV | grep --binary-files=text CKPT
	echo 

	echo -e "Replaying test #$1 ...\n"
	START_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_start)
	END_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_end)
	echo "START_ENTRY is $START_ENTRY"
	echo "END_ENTRY is $END_ENTRY"
	echo 

	sleep 5

	let ENTRY=START_ENTRY
	while [ $ENTRY -lt $END_ENTRY ]; do
		echo "***** Entry #$ENTRY *****"
		${TOOLS_DIR}/replay-log --limit 1 --log $LOGDEV --replay $REPLAYDEV \
			--start $ENTRY || _fail "replay failed"
		echo "CKPT after replay"
		${TOOLS_DIR}/dump.f2fs $REPLAYDEV | grep --binary-files=text CKPT
		${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV > /dev/null 2>&1
		mount -t ${FSTYPE} $REPLAYDEV $CCTESTS_MNT || _fail "mount failed at entry $ENTRY"
		umount $CCTESTS_MNT
		echo "CKPT after mount/umount"
		${TOOLS_DIR}/dump.f2fs $REPLAYDEV | grep --binary-files=text CKPT
		${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV > /dev/null 2>&1
		let ENTRY+=1
		echo
	done
}

consistency()
{
	[ -z $LOGDEV ] && exit "Must set LOGDEV and REPLAYDEV"
	[ -z $REPLAYDEV ] && exit "Must set LOGDEV and REPLAYDEV"
	[ -z $DEVMAP_LOG_WRITES ] && exit "Must set DEVMAP_LOG_WRITES"
	[ ! -d $LOCALS ] && exit "Must create LOCALS directory"

	xfstests_config_gen consistency_tests
	exclude_gen

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

	losetup -d $COW_LOOP_DEV &> /dev/null
	rm -f cow-dev
}

xfstests()
{
	[ ! -d $LOCALS ] && exit "Must create LOCALS directory"

	xfstests_config_gen xfstests
	exclude_gen

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
}

exclude_gen()
{
	# TODO
	cp excludes/{$XFSTESTS_EXCLUDE,$CCTESTS_EXCLUDE} $XFSTESTS_DIR
}

setup_env()
{
	mkdir -p $LOCALS
	pushd src
	
	tar xzvf f2fs-tools.v1.8.0.tar.gz
	pushd f2fs-tools-v1.8.0
	./autogen.sh
	./configure
	make
	make install DESTDIR="$LOCALS"
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
		single test - run a single test
	consistency: check the consistency of f2fs for each BIOs in
		all - all generic tests of xfstests
		single test -  a single test
	mkfs_ckpt_test: check the CKPT in mkfs_end mark
	generate_exclude: generate the exclude files of consistency and xfstests
EOF
} 



export BLKSIZE=$(blockdev --getsz $REPLAYDEV)
export DEVMAP_PART="/dev/mapper/${DEVMAP_LOG_WRITES}"
export TOOLS_DIR="${LOCALS}/usr/local/sbin"
export LIB_DIR="${LOCALS}/usr/local/lib"
export XFSTESTS_DIR="${LOCALS}/var/lib/xfstests"

case $1 in 
	setup_env)
		setup_env
		;;
	clean)
		clean
		;;
	consistency)
		shift 1
		consistency $*
		;;
	xfstests)
		shift 1
		xfstests $*
		;;
	mkfs_ckpt_test)
		ckpt_test $2
		;;
	*)
		print_help
		;;
esac
