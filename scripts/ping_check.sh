#!/bin/bash

hosts=("7c0437ebc41c.mylabserver.com" "7c0437ebc42c.mylabserver.com" "7c0437ebc43c.mylabserver.com")

success=0
failure=0

echo "----------------------"
echo "Total Number Of Variabels are: "${hosts[$0]}""
echo "----------------------"

for host in "${hosts[@]}"
do
    if ping -c 1 -W 2 "$host" > /dev/null 2>&1
    then
        echo "$host is UP"
        ((success++))
    else
        echo "$host is DOWN"
        ((failure++))
    fi
done

echo "----------------------"
echo "Successful hosts: $success"
echo "Failed hosts: $failure"
echo "----------------------"
