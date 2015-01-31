#!/usr/bin/env bash

ME=$(basename $0)
MYDIR=$(dirname $0)
MYDIR=$(cd $MYDIR && pwd)
MYTOPDIR=$(cd $MYDIR/.. && pwd)

sudo apt-get install -y build-essential cmake rsync

wget -O /tmp/cpkg-master.zip https://github.com/chybz/cpkg/archive/master.zip
cd /tmp
rm -rf cpkg-master
unzip cpkg-master.zip
cd cpkg-master
./utils/autoinst.sh
cd $MYTOPDIR
