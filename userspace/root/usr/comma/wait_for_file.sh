#!/bin/bash -e

until [ -e $1 ]
do
  sleep 1
done

