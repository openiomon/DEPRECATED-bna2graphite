Summary: bna2graphite is a module of openiomon which is used to transfer statistics from the Brocade Network Advisor (BNA) to a graphite system to be able to display this statistics in Grafana.
Name: bna2graphite
Version: 0.2
prefix: /opt
Release: 6
URL: http://www.openiomon.org
License: GPL
Group: Applications/Internet
BuildRoot: %{_tmppath}/%{name}-root
Source0: bna2graphite-%{version}.tar.gz
BuildArch: noarch
AutoReqProv: no
Requires: perl(Getopt::Long) perl(IO::Socket::INET) perl(JSON) perl(LWP::UserAgent) perl(LWP::Protocol::https) perl(Log::Log4perl) perl(POSIX) perl(Switch) perl(Time::HiRes) perl(Time::Local) perl(constant) perl(strict) perl(warnings)



%description
Module for integration of Brocade SAN Switch performance and error statistics to Grafana. Data is queried using HTTPrest API from Brocade Network Advisor and send via plain text protocol to graphite / carbon cache systems.

%pre
getent group openiomon >/dev/null || groupadd -r openiomon
getent passwd openiomon >/dev/null || \
    useradd -r -g openiomon -d /opt/bna2graphite -s /sbin/nologin \
    -c "This user will be used for modules of openiomon" openiomon
exit 0

%prep

%setup

%build

%install
rm -rf ${RPM_BUILD_ROOT}
mkdir -p ${RPM_BUILD_ROOT}/opt/bna2graphite/bin/
mkdir -p ${RPM_BUILD_ROOT}/opt/bna2graphite/conf
mkdir -p ${RPM_BUILD_ROOT}/opt/bna2graphite/log/
mkdir -p ${RPM_BUILD_ROOT}/opt/bna2graphite/run/
mkdir -p ${RPM_BUILD_ROOT}/opt/bna2graphite/lib/
mkdir -p ${RPM_BUILD_ROOT}/opt/bna2graphite/legacy/
mkdir -p ${RPM_BUILD_ROOT}/etc/go-carbon/
mkdir -p ${RPM_BUILD_ROOT}/etc/logrotate.d/
install -m 655 %{_builddir}/bna2graphite-%{version}/bin/* ${RPM_BUILD_ROOT}/opt/bna2graphite/bin/
install -m 655 %{_builddir}/bna2graphite-%{version}/conf/*.conf ${RPM_BUILD_ROOT}/opt/bna2graphite/conf/
install -m 655 %{_builddir}/bna2graphite-%{version}/legacy/*.conf.openiomon ${RPM_BUILD_ROOT}/etc/go-carbon/
install -m 655 %{_builddir}/bna2graphite-%{version}/legacy/bna2graphite_logrotate ${RPM_BUILD_ROOT}/etc/logrotate.d/bna2graphite

%clean
rm -rf ${RPM_BUILD_ROOT}

%files
%config(noreplace) %attr(644,openiomon,openiomon) /opt/bna2graphite/conf/*.conf
%config(noreplace) %attr(644,root,root) /etc/go-carbon/*.conf.openiomon
%config(noreplace) %attr(644,root,root) /etc/logrotate.d/bna2graphite
%defattr(644,openiomon,openiomon)
%attr(755,openiomon,openiomon) /opt/bna2graphite
%attr(755,openiomon,openiomon) /opt/bna2graphite/bin
%attr(755,openiomon,openiomon) /opt/bna2graphite/bin/*
%attr(755,openiomon,openiomon) /opt/bna2graphite/conf
%attr(755,openiomon,openiomon) /opt/bna2graphite/log
%attr(755,openiomon,openiomon) /opt/bna2graphite/run
%attr(755,openiomon,openiomon) /opt/bna2graphite/lib

%post
ln -s -f /opt/bna2graphite/bin/bna2graphite.pl /bin/bna2graphite

%changelog
* Mon Aug 28 2019 Timo Drach <timo.drach@openiomon.org>
- Cleanup for publishing RPM on github
* Wed Sep 12 2018 Timo Drach <timo.drach@cse-ub.de>
- Fixed issues with wrong perl file in bin folder
* Mon Sep 03 2018 Timo Drach <timo.drach@cse-ub.de>
- Changed RXP and TXP value detection due to Rest API changes in BNA (measure_name)
* Tue Aug 21 2018 Timo Drach <timo.drach@cse-ub.de>
- Fixed minor issues
* Mon Jan 29 2018 Timo Drach <timo.drach@cse-ub.de>
- Changes users for log files to work as openiomon
- Fixed issues with Target+Initiator End Devices
* Tue Jan 09 2018 Timo Drach <timo.drach@cse-ub.de>
- Added support host to wwpn mapping file
- Added support for import of data based on host and storage names
* Tue Jan 09 2018 Timo Drach <timo.drach@cse-ub.de>
- Added support for dropping service messages from syslog
* Tue Jan 02 2018 Timo Drach <timo.drach@cse-ub.de>
- Added creation of service user openiomon and changed file ownership
- Added logrotate file to build process
* Sat Dec 09 2017 Timo Drach <timo.drach@cse-ub.de>
- Added configuration files for storage schemas and aggregation for go-carbon
* Wed Nov 22 2017 Timo Drach <timo.drach@cse-ub.de>
- Initial version

