#!/bin/bash

dd if=/dev/zero of=cow-dev bs=1M count=1 seek=1048576 2> /dev/null
COW_LOOP_DEV=$(losetup -f --show cow-dev)

. fsck_scripts/fsck_config
. utils/log

trap "_fail 'fsck_snap cancelled!'; exit -1;" 2 15

_fail()
{
	_log $1
	umount $TARGET &> /dev/null
	if [ "$FSTYPE" == "f2fs" ]; then
		echo "########## -d 3 of REPLAYING $ENTRY_NUM ##########" >> ${TESTS_FSCK_LOG}
		${TOOLS_DIR}/fsck.f2fs -d 3 $TARGET >> ${TESTS_FSCK_LOG}
	fi
	if [ -b $SNAPSHOTBASE_DEV ]; then
		dmsetup remove -f $SNAPSHOTCOW
		dmsetup remove -f $SNAPSHOTBASE
	fi
	losetup -d $COW_LOOP_DEV &> /dev/null
        rm -f cow-dev &> /dev/null
}

# Check the consistency of file system
if [ $DEBUG == "ON" ]; then
	FSCK_DEBUG="| tee -a"
else
	FSCK_DEBUG=">>"
fi


echo "########## REPLAYING $ENTRY_NUM ##########" >> ${TESTS_FSCK_LOG}
echo "########## REPLAYING $ENTRY_NUM ##########" >> ${TESTS_CKPT_LOG}

CKPT=$(${TOOLS_DIR}/dump.f2fs $REPLAYDEV | grep --binary-files=text CKPT | cut -d= -f2)
echo -e "CKPT of REPLAYDEV: $CKPT" >> ${TESTS_CKPT_LOG}

# Create snapshot-origin and snapshot targets to prevent changing
# the disk layout and specifically CKPT after each mount and umount
dmsetup create $SNAPSHOTBASE --table "$ORIGIN_TABLE"
if [ $? -ne 0 ]
then
	# Sometimes this looping is too fast for device-mapper and
	# we get a random EBUSY, so just sleep for a sec and try
	# again.
	sleep 1
	dmsetup create $SNAPSHOTBASE --table "$ORIGIN_TABLE" || \
		{ _fail "Creating snapshot-origin target failed at entry $ENTRY_NUM."; exit -1; }
fi

dmsetup create $SNAPSHOTCOW --table "$COW_TABLE" 
if [ $? -ne 0 ]; then
	sleep 1
	dmsetup create $SNAPSHOTCOW --table "$COW_TABLE" || \
		{ _fail "Creating snapshot target failed at entry $ENTRY_NUM."; exit -1; }
fi

CKPT=$(${TOOLS_DIR}/dump.f2fs $TARGET | grep --binary-files=text CKPT | cut -d= -f2)
echo -e "CKPT of SNAPSHOTCOW: $CKPT" >> ${TESTS_CKPT_LOG}

eval ${TOOLS_DIR}/${FSCK} $FSCK_OPTS $TARGET ${FSCK_DEBUG} ${TESTS_FSCK_LOG} ||\
	{ _fail "fsck failed at entry $ENTRY_NUM."; exit -1; }


mount -t ${FSTYPE} $TARGET $MNT ||\
	{ _fail "mount failed at entry $ENTRY_NUM."; exit -1; }

umount $MNT &> /dev/null
if [ $? -ne 0 ]; then
	sleep 1
	umount $MNT &> /dev/null ||\
	{ _fail "umount failed at entry $ENTRY_NUM."; exit -1; }
fi

CKPT=$(${TOOLS_DIR}/dump.f2fs $TARGET | grep --binary-files=text CKPT | cut -d= -f2)
echo -e "CKPT of SNAPSHOTCOW after mount/umount: $CKPT" >> ${TESTS_CKPT_LOG}

eval ${TOOLS_DIR}/${FSCK} $FSCK_OPTS $TARGET ${FSCK_DEBUG} ${TESTS_FSCK_LOG} ||\
	{ _fail "fsck failed at entry $ENTRY_NUM."; exit -1; }

# Remove all snapshot targets
dmsetup remove -f $SNAPSHOTCOW
if [ $? -ne 0 ]; then
	sleep 1
	dmsetup remove $SNAPSHOTCOW  || \
	{ _fail "Removing snapshot target failed at entry $ENTRY_NUM."; exit -1; }
fi

dmsetup remove -f $SNAPSHOTBASE
if [ $? -ne 0 ]; then
	sleep 1
	dmsetup remove $SNAPSHOTBASE  || \
{ _fail "Removing snapshot-origing failed at entry $ENTRY_NUM."; exit -1; }
fi

losetup -d $COW_LOOP_DEV &> /dev/null
rm -f cow-dev &> /dev/null

CKPT=$(${TOOLS_DIR}/dump.f2fs $REPLAYDEV | grep --binary-files=text CKPT | cut -d= -f2)
echo -e "CKPT of REPLAYDEV: $CKPT" >> ${TESTS_CKPT_LOG}


