#!/usr/bin/python

import sys
import os
import re
from itertools import islice

filepath = sys.argv[1];
if not os.path.isfile(filepath):
    print "File Doesn't exist."
    sys.exit()
with open(filepath,"r") as ckpt_log:
    while True:
        replay_log = list(islice(ckpt_log, 5))
        if len(replay_log) == 0 or len(replay_log) == 1 :
            break
        REPLAYDEVObj1 = re.search(r'(.+):  (.+)\n', replay_log[1])
        REPLAYDEV1 = REPLAYDEVObj1.group(2)
        
        SNAPSHOTDEVObj = re.search(r'(.+):  (.+)\n', replay_log[2])
        SNAPSHOTDEV = SNAPSHOTDEVObj.group(2)

        POSTMOUNT_SNAPSHOTDEVObj = re.search(r'(.+):  (.+)\n', replay_log[3])
        POSTMOUNT_SNAPSHOTDEV = POSTMOUNT_SNAPSHOTDEVObj.group(2)

        REPLAYDEVObj2 = re.search(r'(.+):  (.+)\n', replay_log[4])
        REPLAYDEV2 = REPLAYDEVObj2.group(2)
#         print REPLAYDEV1, SNAPSHOTDEV, POSTMOUNT_SNAPSHOTDEV, REPLAYDEV2
        
        if (REPLAYDEV1 != REPLAYDEV2 or REPLAYDEV1 != SNAPSHOTDEV or REPLAYDEV2 != SNAPSHOTDEV):
            for i in range(5):
                print replay_log[i],
            print "\nCKPT inconsistency!!! (Error)"
            break
