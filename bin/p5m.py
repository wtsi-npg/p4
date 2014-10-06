#!/usr/bin/python
#
# P4 Process Monitor
#
# Looks at all the jobs for the pipeline, and returns a status for each one
# Also returns information about the pipeline as a whole
#
# This job is run automatically by viv (p4) when it launches the exec nodes, and is 
# killed by viv (p4) when all of the other children have finished. It is not designed
# to be run as a stand-alone program.
#
# When viv executes this program, it passes the vtf_name and log_dir as paramaters
# 
# returns a status for each job
# 
# 0     job has completed
# 1     job is waiting for input or output
# 2     job is currently executing
# 

import socket
import struct
import sys
import glob
import json
import re
import subprocess
import os

multicast_group = '224.3.28.70'
server_address = (multicast_group, 10000)

vtf_name = sys.argv[1]
log_dir = sys.argv[2] + '/'

log_files = glob.glob(log_dir+'*.err')
data = {}
data['vtf_name'] = vtf_name
data['log_dir'] = log_dir
data['hostname'] = socket.gethostname()
data['pid'] = os.getppid()

# Read the VTF (or json) file
vtf_file=open(vtf_name)
vtf_data = json.load(vtf_file)
vtf_file.close()
data['vtf_data'] = json.dumps(vtf_data)

# Create the socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

# Bind to the server address
sock.bind(server_address)

# Tell the operating system to add the socket to the multicast group
# on all interfaces.
group = socket.inet_aton(multicast_group)
mreq = struct.pack('4sL', group, socket.INADDR_ANY)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)

# Receive/respond loop
while True:
	# wait until we get a request for information
    # it doesn't really matter *what* we receive....but it's 'ping'
    # if we want to respond differently to different requests, then we
    # need to check the recdata here...
    recdata, address = sock.recvfrom(1024)

    nodes = {}

    for log_file in log_files:
        matches = re.match(log_dir+'(.*)\.(\d*)\.err',log_file)
        if (matches):
            pid = matches.group(2)
            cmd = ("ps", "--no-heading", "-o", "command", "-p", pid)
            try:
                output = subprocess.check_output(cmd)
                m1 = re.search("STDIN:",output)
                m2 = re.search("STDOUT:",output)
				# Job is currently running
                status = 2
                if (m1 or m2):
                    # Job is waiting for I/O
                    status = 1
            except:
				# Job has completed
                status = 0

            nodes[matches.group(1)] = status


    data['nodes'] = nodes

    # since viv starts this program first, the command below returns the elapsed time that the pipeline has been running
    cmd = ("ps", "--no-heading", "-o", "etime", str(os.getpid()))
    data['etime'] = subprocess.check_output(cmd)

    # package the data up and return it
    json_data = json.dumps(data)
    sock.sendto(json_data, address)

