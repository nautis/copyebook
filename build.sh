#!/bin/bash
set -e
cd "$(dirname "$0")"
swiftc -parse-as-library -O -o copyebook copyebook.swift
echo "Built: ./copyebook"
