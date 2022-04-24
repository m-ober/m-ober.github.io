---
title: "My GSoC 2022 project: SerialICE x coreboot"
date: 2022-04-22T17:46:59+02:00
tags: ['gsoc', 'coreboot', 'serialice', 'hardware']
draft: true
---

# Introduction

Analyzing firmware is a common and often tedious task, but it’s required to add support for new mainboards to coreboot. Thus, simplyfing this process is of great interest for coreboot development.

To understand how SerialICE can facilitate this process, let’s first have a look at the components:
* Host: Your PC, probably some x86 machine
* QEMU: Open-source hardware emulator
* Target Firmware: The firmware which is to be analyzed
* Target / Mainboard: The Device under Test (DUT)
* SerialICE Stub: A minimal firmware which receives commands and passes it on to the hardware

What we are actually doing here is a MITM - using QEMU we can record and analyze all commands the firmware is exceuting, and we do that conveniently on our powerful host PC.

![Example image](/images/serialice-coreboot.png)

In order for this to work, the SerialICE Stub has to bring up a serial interface on the target hardware. Currently, the development of coreboot and SerialICE is separated. My proposal within the scope of GSoC is to integrate the SerialICE Stub into coreboot. Thus, both projects would greatly benefit: SerialICE profits from new hardware added to coreboot and coreboot will have an integrated tool for firmware analysis.
