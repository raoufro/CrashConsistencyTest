#!/bin/bash -x

. config || {
cat << EOF
	There is no config file in current directory.
	See config.sample as an exmaple.
EOF
	exit 1
}



_fail()
{
	echo $1
	umount ${DEVMAP_PART} > /dev/null 2>&1
	dmsetup remove ${DEVMAP_LOG_WRITES} > /dev/null 2>&1
	exit 1
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
			echo "Hi"
			;;
		consistency_tests)
			echo -e "[${FSTYPE}_consistency]\n"\
			"TEST_DEV=$DEVMAP_PART\n"\
			"TEST_DIR=$CCTESTS_MNT\n"\
			"FSTYP=$FSTYPE\n"\
			"MOUNT_OPTTION=\"$MOUNT_OPTS\"\n"\
			"RESULT_BASE=${RESULT_DIR}/consistency_tests/${CUR_DATE}"\
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
	./check -s ${FSTYPE}_consistency generic/$1
	popd > /dev/null
	dmsetup message ${DEVMAP_LOG_WRITES} 0 mark $1_end


	# Remove log-writes
	dmsetup remove ${DEVMAP_LOG_WRITES}
}

apply_consistency_test()
{
	echo "Replaying mkfs ..."
	ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark mkfs_end)
	${TOOLS_DIR}/replay-log --log $LOGDEV --replay $REPLAYDEV --limit $ENTRY || _fail "mkfs replay failed-$LINENO" 

	START_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_start)
	END_ENTRY=$(${TOOLS_DIR}/replay-log --log $LOGDEV --find --end-mark $1_end)

	echo "START_ENTRY is $START_ENTRY"
	echo "END_ENTRY is $END_ENTRY"
	
	echo -e "Replaying test #$1 ...\n\n"
	let ENTRY=START_ENTRY+1
	while [ $ENTRY -lt $END_ENTRY ]; do
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
}

consistency_tests()
{
	[ -z $LOGDEV ] && exit "Must set LOGDEV and REPLAYDEV"
	[ -z $REPLAYDEV ] && exit "Must set LOGDEV and REPLAYDEV"
	[ -z $DEVMAP_LOG_WRITES ] && exit "Must set DEVMAP_LOG_WRITES"
	[ ! -d $LOCALS ] && exit "Must create LOCALS directory"

	xfstests_config_gen consistency_tests
	for aTest in $(ls $XFSTESTS_DIR/tests/generic | egrep "^[0-9]*$" | sort -n); do
		apply_test $aTest
		apply_consistency_test $aTest
	done

}

xfstests()
{
	[ ! -d $LOCALS ] && exit "Must create LOCALS directory"

	xfstests_config_gen xfstests
	pushd ${XFSTESTS_DIR}
	./check -s ${FSTYPE}_xfstests
	popd 
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
	consistency: run generic tests of xfstests in log-writes mode
	xfstests: run xfstests related to FSTYPE
EOF
} 



BLKSIZE=$(blockdev --getsz $REPLAYDEV)
DEVMAP_PART="/dev/mapper/${DEVMAP_LOG_WRITES}"
TOOLS_DIR="${LOCALS}/usr/local/sbin"
LIB_DIR="${LOCALS}/usr/local/lib"
XFSTESTS_DIR="${LOCALS}/var/lib/xfstests"

case $1 in 
	setup_env)
		setup_env
		;;
	clean)
		clean
		;;
	consistency)
		consistency_tests
		;;
	xfstests)
		xfstests
		;;
	*)
		print_help
		;;
esac
