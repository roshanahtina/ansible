#!/bin/bash
name=$1

if [ -n $name ]
then
echo "Package is supplied $name and running Ansible Ad-Hoc Command"
else
echo "Package is NoT supplied"
  exit
fi

echo "Sleep 2 Mins"

sleep 2

ansible -i /etc/ansible/inv.ini testclients -m yum -a "name=$name state=present"
