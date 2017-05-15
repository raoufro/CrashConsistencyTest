#!/bin/bash

. fsck_scripts/fsck_config
. utils/log

trap "_fail 'fsck_inconsistent cancelled!'; exit -1;" 2 15
_fail()
{
	_log $1
}

echo "########## REPLAYING $ENTRY_NUM ##########" >> ${TESTS_FSCK_LOG}

# Check the consistency of file system

eval ${TOOLS_DIR}/${FSCK} $FSCK_OPTS $TARGET >> ${TESTS_FSCK_LOG} ||\
	{ _fail "fsck failed at entry $ENTRY_NUM."; exit -1; }

mount -t ${FSTYPE} $TARGET $MNT ||\
	{ _fail "mount failed at entry $ENTRY_NUM."; exit -1; }

umount $MNT &> /dev/null
if [ $? -ne 0 ]; then
	sleep 1
	umount $MNT ||\
	{ _fail "umount failed at entry $ENTRY_NUM."; exit -1; }
fi

eval ${TOOLS_DIR}/${FSCK} $FSCK_OPTS $TARGET >> ${TESTS_FSCK_LOG} ||\
	{ _fail "fsck failed at entry $ENTRY_NUM."; exit -1; }
