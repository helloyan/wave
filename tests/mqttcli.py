#!/usr/bin/env python
# -*- coding: UTF8 -*-

import time
import random
from nyamuk import nyamuk
from nyamuk.event import *
import nyamuk.nyamuk_const as NC

class MqttClient(object):
    def __init__(self, prefix, rand=True, **kwargs):
        self._c = nyamuk.Nyamuk("test:{0}:{1}".format(prefix, random.randint(0,9999) if rand else 0), None, None, 'localhost',
            **kwargs)

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

    def get_last_mid(self):
        return self._c.get_last_mid()

    def recv(self):
        self._c.loop()
        return self._c.pop_event()

    def __getattr__(self, name):
        def _(*args, **kwargs):
            return self.do(name, *args, **kwargs)
            
        return _

