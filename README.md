# Table of Contents

* [Features](#features)
* [Installation](#installation)
* [Configuration](#configuration)
* [Changelog](#changelog)
* [Disclaimer](#disclaimer)

# bna2graphite

A tool to retrieve Broadcom (Brocade) SAN Switch Performance counters from Brocade Network Advisor REST API and write them to a Carbon/Graphite backend.
* Written in Perl.
* tested on RHEL / CentOS 7
* works with BNA 14.4
* RPM package available

## Features
* Add one or more BNA server instances
* configurable retrival time
* configurable metrics
* Workers run as systemd service

## Installation
Install on RHEL via RPM package: `yum install bna2graphite-0.x.x.rpm`

Perl dependencies that are not available in RHEL / CentOS 7 repositories:
* Log::Log4perl (RPM perl-Log-Log4perl available in [EPEL repository](https://fedoraproject.org/wiki/EPEL))
* Systemd::Daemon (included in the release package, [view in CPAN](https://metacpan.org/pod/Systemd::Daemon))

For other Linux distributions you can just clone the repository. Default installation folder is `/opt/bna2graphite`. The service operates with a use called "openiomon"

## Configuration
1. Edit the `/opt/bna2graphite/conf/bna2graphite.conf`, settings you have to edit for a start:

* Specifiy the connection parameter to the BNA server  
`[BNA]`  
`<Server name>;<User name>;<Password>`

* Specify the connection to your carbon/graphite backend  
`[graphite]`  
`host = 127.0.0.1`  
`port = 2003`  

2. Create a service
`/opt/bna2graphite/bin/bna2graphite.pl -register <Server name>`

3. Enable the service
`/opt/bna2graphite/bin/bna2graphite.pl -enable <Server name>`

4. Start the service
`/opt/bna2graphite/bin/bna2graphite.pl -start <Server name>`

## Changelog
### 0.2.5
* First public release

# Disclaimer
This source and the whole package comes without warranty. It may or may not harm your computer. Please use with care. Any damage cannot be related back to the author.
