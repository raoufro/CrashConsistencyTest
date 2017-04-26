#!/bin/bash

. config
. utils/log

trap "_fail 'fsck_snap cancelled!'; exit -1;" 2 15

_fail()
{
	_log $1
	umount $TARGET &> /dev/null
	if [ -b $SNAPSHOTBASE_DEV ]; then
		dmsetup remove -f $SNAPSHOTCOW
		dmsetup remove -f $SNAPSHOTBASE
	fi
}

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

# Check the consistency of file system
[ $_DEBUG == "OFF" ] && FSCK_DEBUG="> /dev/null 2>&1"

eval ${TOOLS_DIR}/${FSCK} $FSCK_OPTS $TARGET "${FSCK_DEBUG}" ||\
	{ _fail "fsck failed at entry $ENTRY_NUM."; exit -1; }

mount -t ${FSTYPE} $TARGET $CCTESTS_MNT ||\
	{ _fail "mount failed at entry $ENTRY_NUM."; exit -1; }

umount $CCTESTS_MNT &> /dev/null
if [ $? -ne 0 ]; then
	sleep 1
	umount $CCTESTS_MNT &> /dev/null ||\
	{ _fail "umount failed at entry $ENTRY_NUM."; exit -1; }
fi

eval ${TOOLS_DIR}/${FSCK} $FSCK_OPTS $TARGET "${FSCK_DEBUG}" ||\
	{ _fail "fsck failed at entry $ENTRY_NUM."; exit -1; }

# Remove snapshot* targets
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

