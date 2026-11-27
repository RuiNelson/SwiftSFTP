#!/bin/zsh

# swiftformat-ruinelson is a SwiftFormat build with the reflowComments rule, usually defined as an alias in
# ~/.zshrc. Scripts don't load aliases, so ask an interactive shell what it points to.
ruinelson=$(zsh -ic 'whence swiftformat-ruinelson' 2>/dev/null)

if [[ -n "$ruinelson" && -x "$ruinelson" ]]; then
	"$ruinelson" Sources Tests Package.swift --config .swiftformat,.swiftformat-ruinelson
else
	swiftformat Sources Tests Package.swift
fi
