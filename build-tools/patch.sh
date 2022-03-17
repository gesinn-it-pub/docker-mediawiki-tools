#!/bin/bash
FILE=$1
patch "$FILE" "/patches/$FILE.diff"
