SPOON_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

all: $(SPOON_DIR)winmove

$(SPOON_DIR)winmove: $(SPOON_DIR)winmove.swift
	swiftc -O -o $@ $< -framework ApplicationServices

clean:
	rm -f $(SPOON_DIR)winmove

.PHONY: all clean
