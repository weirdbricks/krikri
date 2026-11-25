#!/usr/bin/python3
"""Deterministic fact source for the issue #1788 corpus case.

The role loops over `ansible_interfaces`, whose length and contents come
from the target host, so no fixed expected.out could replay that loop's
per-item lines. This module reports the same shape - a one-element list
under an `ansible_facts` entry - so both engines inject it as a top-level
fact named `ifaces` and the with_items: deprecation the issue is about is
reproduced host-independently.
"""

import json

if __name__ == "__main__":
    print(json.dumps({"changed": False, "ansible_facts": {"ifaces": ["eth0"]}}))
