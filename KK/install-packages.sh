#!/bin/bash
name=$1

if [ -n $name ]
then
echo "Package is supplied $name and running Ansible Ad-Hoc Command"
else
echo "Package is NoT supplied"
  exit
fi

sleep 10

ansible -i /etc/ansible/inv.ini testclients -m yum -a "name=$name state=present"
