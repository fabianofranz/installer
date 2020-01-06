#!/usr/bin/env python3

import json
import base64
import sys
import os
from dotmap import DotMap

url = sys.argv[1]
storageAccountName = sys.argv[2]
sshkey = sys.argv[3]

ign = DotMap()
config = DotMap()
ign.ignition.version = "2.2.0"
config.replace.source = url
ign.ignition.config = config

ignstr = json.dumps(dict(**ign.toDict()))

imageURL = 'https://' + storageAccountName + '.blob.core.windows.net/vhd/rhcos.vhd'

with open("master.ign", "r") as ignFile:
    master_ignition = json.load(ignFile)

with open("worker.ign", "r") as ignFile:
    worker_ignition = json.load(ignFile)

with open("02_storage.template.json", "r") as jsonFile:
    data = DotMap(json.load(jsonFile))
    data.parameters.image.value = imageURL
    jsondata = dict(**data.toDict())
    with open("04_bootstrap.parameters.json", "w") as jsonFile:
        json.dump(jsondata, jsonFile)

with open("04_bootstrap.template.json", "r") as jsonFile:
    data = DotMap(json.load(jsonFile))
    data.parameters.BootstrapIgnition.value = base64.b64encode(ignstr.encode()).decode()
    data.parameters.sshKeyData.value = sshkey.rstrip()
    jsondata = dict(**data.toDict())
    with open("04_bootstrap.parameters.json", "w") as jsonFile:
        json.dump(jsondata, jsonFile)

with open("05_masters.template.json", "r") as jsonFile:
    data = DotMap(json.load(jsonFile))
    data.parameters.MasterIgnition.value = base64.b64encode(json.dumps(master_ignition).encode()).decode()
    data.parameters.sshKeyData.value = sshkey.rstrip()
    jsondata = dict(**data.toDict())
    with open("05_masters.parameters.json", "w") as jsonFile:
        json.dump(jsondata, jsonFile)

with open("06_workers.template.json", "r") as jsonFile:
    data = DotMap(json.load(jsonFile))
    data.parameters.WorkerIgnition.value = base64.b64encode(json.dumps(worker_ignition).encode()).decode()
    data.parameters.sshKeyData.value = sshkey.rstrip()
    jsondata = dict(**data.toDict())
    with open("06_workers.parameters.json", "w") as jsonFile:
        json.dump(jsondata, jsonFile)
