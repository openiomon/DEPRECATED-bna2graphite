Summary: bna2graphite is a module of openiomon which is used to transfer statistics from the Brocade Network Advisor (BNA) to a graphite system to be able to display this statistics in Grafana.
Name: bna2graphite
Version: 0.2
prefix: /opt
Release: 10
URL: http://www.openiomon.org
License: GPL
Group: Applications/Internet
BuildRoot: %{_tmppath}/%{name}-root
Source0: bna2graphite-%{version}.tar.gz
BuildArch: x86_64
AutoReqProv: no
Requires: perl(version) perl(Readonly) perl(Getopt::Long) perl(IO::Socket::INET) perl(JSON) perl(LWP::UserAgent) perl(LWP::Protocol::https) perl(Log::Log4perl) perl(POSIX) perl(Time::HiRes) perl(Time::Local) perl(constant) perl(strict) perl(warnings)



%description
Module for integration of Brocade SAN Switch performance and error statistics to Grafana. Data is queried using HTTPrest API from Brocade Network Advisor and send via plain text protocol to graphite / carbon cache systems.

%pre
getent group openiomon >/dev/null || groupadd -r openiomon
getent passwd openiomon >/dev/null || \
    useradd -r -g openiomon -d /home/openiomon -s /sbin/nologin \
    -c "openiomon module daemon user" openiomon
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
mkdir -p ${RPM_BUILD_ROOT}/opt/bna2graphite/dashboards/
mkdir -p ${RPM_BUILD_ROOT}/opt/bna2graphite/build/
mkdir -p ${RPM_BUILD_ROOT}/etc/logrotate.d/
install -m 655 %{_builddir}/bna2graphite-%{version}/bin/* ${RPM_BUILD_ROOT}/opt/bna2graphite/bin/
install -m 655 %{_builddir}/bna2graphite-%{version}/conf/*.conf ${RPM_BUILD_ROOT}/opt/bna2graphite/conf/
install -m 655 %{_builddir}/bna2graphite-%{version}/conf/*.example ${RPM_BUILD_ROOT}/opt/bna2graphite/conf/
install -m 655 %{_builddir}/bna2graphite-%{version}/build/bna2graphite_logrotate ${RPM_BUILD_ROOT}/etc/logrotate.d/bna2graphite
#install -m 655 %{_builddir}/bna2graphite-%{version}/lib/* ${RPM_BUILD_ROOT}/opt/bna2graphite/lib
cp -a %{_builddir}/bna2graphite-%{version}/lib/* ${RPM_BUILD_ROOT}/opt/bna2graphite/lib/
cp -a %{_builddir}/bna2graphite-%{version}/dashboards/*.json ${RPM_BUILD_ROOT}/opt/bna2graphite/dashboards/

%clean
rm -rf ${RPM_BUILD_ROOT}

%files
%config(noreplace) %attr(644,openiomon,openiomon) /opt/bna2graphite/conf/*.conf
%config(noreplace) %attr(644,root,root) /etc/logrotate.d/bna2graphite
%attr(755,openiomon,openiomon) /opt/bna2graphite/bin/*
%attr(755,openiomon,openiomon) /opt/bna2graphite/lib/perl5/
%defattr(644,openiomon,openiomon,755)
/opt/bna2graphite/conf/storage-schemas.conf.example
/opt/bna2graphite/dashboards/*
/opt/bna2graphite/log/
/opt/bna2graphite/run/


%post
ln -s -f /opt/bna2graphite/bin/bna2graphite.pl /bin/bna2graphite

%changelog
* Sun Nov 17 2019 Timo Drach <timo.drach@openiomon.org>
- Added dashboards and dashboard-utilities to RPM package
* Tue Oct 01 2019 Timo Drach <timo.drach@openiomon.org>
- Added example go-carbon storageschema configfile
* Wed Sep 25 2019 Timo Drach <timo.drach@openiomon.org>
- Stripped down version of systed perl library
* Wed Sep 18 2019 Timo Drach <timo.drach@openiomon,org>
- Including the systemd perl library in RPM and changing RPM architecture
* Mon Aug 26 2019 Timo Drach <timo.drach@openiomon.org>
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

