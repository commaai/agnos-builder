#!/bin/bash -e

until [ -e "$1" ]
do
  sleep 0.01
done

