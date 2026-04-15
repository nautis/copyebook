#!/bin/bash
set -e
cd "$(dirname "$0")"
swiftc -parse-as-library -O -o bookmuncher bookmuncher.swift
echo "Built: ./bookmuncher"
