#!/bin/bash -x

. config

trap "_fail 'fsck_inconsistent cancelled!'; exit 1;" 2 15
_fail()
{
	echo $1
}

# Check the consistency of file system
[ $_DEBUG == "OFF" ] && FSCK_DEBUG="> /dev/null 2>&1"

eval ${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV "${FSCK_DEBUG}" \
	|| _fail "fsck failed at entry $ENTRY"
mount -t ${FSTYPE} $REPLAYDEV $CCTESTS_MNT || _fail "mount failed"
echo
umount $CCTESTS_MNT
if [ $? -ne 0 ]; then
	sleep 1
	umount $CCTESTS_MNT
fi
eval ${TOOLS_DIR}/${FSCK} $FSCK_OPTS $REPLAYDEV "${FSCK_DEBUG}" \
	|| _fail "fsck failed"
