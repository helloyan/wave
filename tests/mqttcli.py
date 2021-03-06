#!/usr/bin/env python
# -*- coding: UTF8 -*-

import os
import time
import random
import logging
from nyamuk import nyamuk
from nyamuk.event import *
import nyamuk.nyamuk_const as NC
from nyamuk.mqtt_pkt import MqttPkt

def _zero_generator():
    while True: yield 0
zero_generator=_zero_generator()

def _seq_generator():
    seq = 1
    while True:
        yield seq
        seq += 1
seq_generator=_seq_generator()

def _rand_generator():
    while True: yield random.randint(0, 9999)
rand_generator=_rand_generator()


class MqttClient(object):
    def __init__(self, client_id="testsuite:{seq}", connect=False, raw_connect=False, **kwargs):
        loglevel = logging.DEBUG; logfile = None

        DEBUG   = os.environ.get('DEBUG', '0')
        if DEBUG == '0':
            loglevel  = logging.WARNING
        elif DEBUG != '1':
            logfile   = DEBUG

        clean_session = kwargs.pop('clean_session', 1)
        self._connack = None
        read_connack  = kwargs.pop('read_connack', True)
        server = 'localhost'

        self.client_id = client_id.format(
            zero=zero_generator.next(),
            seq=seq_generator.next(),
            rand=rand_generator.next()
        )
        #print "clientid=", self.client_id

        self._c = nyamuk.Nyamuk(self.client_id, server=server, log_level=loglevel, log_file=logfile, **kwargs)

        # MQTT connection
        #
        # connect takes protocol version (3 or 4) or is True (set version to 3)
        if connect is not False:
            version = connect if isinstance(connect, int) else 3
            self._c.connect(version=version, clean_session = clean_session)
            if read_connack:
                self._connack = self.recv()
            return

        # open TCP connection
        #
        port = 1883
        if raw_connect:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            try:
                sock.connect((server, port))
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                sock.setblocking(1)
                #sock.settimeout(.5)
            except Exception as e:
                raise e

            self._c.sock = sock
    
    def connack(self):
        return self._connack

    def disconnect(self):
        self._c.disconnect(); self._c.packet_write()

    def do(self, action, *args, **kwargs):
        read_response = kwargs.pop('read_response', True)
        retcode = getattr(self._c, action)(*args, **kwargs)

        if retcode != NC.ERR_SUCCESS:
            return retcode

        r = self._c.packet_write()
        r = self._c.loop()

        if not read_response:
            return retcode # NC.ERR_SUCCESS

        return self._c.pop_event()

    def clientid(self):
        return self._c.client_id

    def get_last_mid(self):
        return self._c.get_last_mid()

    def conn_is_alive(self):
        return self._c.conn_is_alive()

    def recv(self):
        self._c.packet_write()
        self._c.loop()
        return self._c.pop_event()

    def __getattr__(self, name):
        def _(*args, **kwargs):
            return self.do(name, *args, **kwargs)
            
        return _

    #
    # forge a "raw" MQTT packet, and send it
    #
    # fields: list of tuples (type, value)
    # ie: [('str', "MQTT"),('bytes', 
    def forge(self, command, flags, fields, send=False):
        rlen = 0
        for (xtype, value) in fields:
            if xtype == 'string':
                rlen += len(value) + 2 # 2 = uint16 = storing string len
            elif xtype == 'byte':
                rlen += 1
            elif xtype == 'uint16':
                rlen += 2
            elif xtype == 'bytes':
                rlen += len(value)

        pkt = MqttPkt()
        pkt.command = command | flags
        pkt.remaining_length = rlen
        pkt.alloc()

        for (xtype, value) in fields:
            if xtype == 'bytes':
                pkt.write_bytes(value, len(value))
            else:
                getattr(pkt, "write_"+xtype)(value)

        if not send:
            return

        #return self.packet_queue(pkt)
        self._c.packet_queue(pkt)
        self._c.loop()
        return self._c.loop() # return status (success, ...)

    # quite of "unproper" release
    # force TCP socket to close immediatly
    def destroy(self):
        self._c.sock.shutdown(socket.SHUT_RDWR)
        self._c.sock.close()

