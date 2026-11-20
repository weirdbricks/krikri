#!/bin/bash
VERSIONS=${VERSIONS:-"2.7.8.10"}

# make directory
sudo mkdir -p /opt/bin
cd /opt

sudo wget http://downloads.activestate.com/ActivePython/releases/${VERSIONS}/ActivePython-${VERSIONS}-linux-x86_64.tar.gz
sudo tar -xzvf ActivePython-${VERSIONS}-linux-x86_64.tar.gz

sudo mv ActivePython-${VERSIONS}-linux-x86_64 apy && cd apy && sudo ./install.sh -I /opt/python/

sudo ln -s /opt/python/bin/easy_install /opt/bin/easy_install
sudo ln -s /opt/python/bin/pip /opt/bin/pip
sudo ln -s /opt/python/bin/python /opt/bin/python
sudo ln -s /opt/python/bin/virtualenv /opt/bin/virtualenv

sudo /opt/bin/pip install docker-py==1.8.1
