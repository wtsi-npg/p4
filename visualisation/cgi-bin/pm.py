#
# Module to return a list of viv instances, with status details for each instance.
#
# It works by sending a message to all currently running instances, then 
# aggregating that data into a list, which it returns.
#
# The return value is therefore a list of JSON format strings
#

import socket
import sys
import struct
import json

def getAll():
    message = 'ping'
    multicast_group = ('224.3.28.70', 10000)

    data = []

    # Create the datagram socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    # Set a timeout so the socket does not block indefinitely when trying
    # to receive data.
    sock.settimeout(2)

    # Set the time-to-live for messages so they do not go past the
    # local network segment.
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)

    try:

        # Send data to the multicast group
        sent = sock.sendto(message, multicast_group)

        # Look for responses from all recipients
        while True:
            try:
                recdata, server = sock.recvfrom(1024 * 16)
            except socket.timeout:
                break
            else:
                data.append(recdata);

    finally:
        sock.close()

    # sort data by elapsed time before returning it
    data.sort(key = lambda d: json.loads(d)['etime'])
    return data

if __name__ == '__main__':
    data = getAll();
    for d in data:
        print d


