#!/bin/bash

. config

trap "exit 1" 2 15
_fail()
{
	echo $1
	umount ${DEVMAP_PART} > /dev/null 2>&1
	dmsetup remove ${DEVMAP_LOG_WRITES} > /dev/null 2>&1
	exit 1
}

if [ $DEBUG == "ON" ]; then
	${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV \
		|| _fail "fsck failed at entry $ENTRY"
	echo 
	mount -t ${FSTYPE} $REPLAYDEV $CCTESTS_MNT || _fail "mount failed at entry $ENTRY"
	umount $CCTESTS_MNT
	${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV \
		|| _fail "fsck failed after umount at entry $ENTRY"
	echo 
else
	${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV > /dev/null 2>&1 \
		|| _fail "fsck failed at entry $ENTRY"
	mount -t ${FSTYPE} $REPLAYDEV $CCTESTS_MNT || _fail "mount failed at entry $ENTRY"
	umount $CCTESTS_MNT
	${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV > /dev/null 2>&1 \
		|| _fail "fsck failed after umount at entry $ENTRY"
fi

