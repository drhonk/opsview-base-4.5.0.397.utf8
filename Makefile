# AUTHORS:
#	Copyright (C) 2003-2013 Opsview Limited. All rights reserved
#
#    This file is part of Opsview
#
#    Opsview is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    Opsview is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with Opsview; if not, write to the Free Software
#    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
# The premise is that make will compile everything
# Then make install will install everything
# If you run "make install DESTDIR=/tmp/build", then will install files into /tmp/build for packaging
# Check that /usr/local/nagios does not have any files in there

# This sets the version of the packages
BASE_VERSION = 4.5.0
BUILD_AND_DATE := $(shell ./get_version)
REVISION := $(shell echo ${BUILD_AND_DATE} | awk '{print $$1}')
VERSION = ${BASE_VERSION}.${REVISION}
RELEASE = 1

NAGIOS = nagios-4.0.20130912
# using git checkout 2012-07-18: 3c10d84ea21c91c4f14cb241f5c7f24e4536476a
NAGIOSPLUG = nagios-plugins-1.4.17-dev
NAGIOSPLUG_CONFIGURE_PERL_MODULES = --enable-perl-modules
CHECK_RADIUS_IH = check_radius_ih-1.1
NRPE = nrpe-2.14
NSCA = nsca-2.7.2
JSCAL = jscalendar-1.0
SCRIPT = scriptaculous-js-1.8.3
VALIDATION = validation-1.5.4.1
NAGIOSGRAPH = nagiosgraph-0.8.2
ALTINITYPLUG = altinity-plugins
FABTABULOUS = fabtabulous
NAGVIS = nagvis-1.4.4
DATATABLESMAJOR = dataTables-1.4
DATATABLES = ${DATATABLESMAJOR}.3
PROTOTYPEXTENSIONS = prototypextensions-0.1.2
TIMELINEVER = 2.3.0
TIMELINE = timeline-libraries-${TIMELINEVER}
TANGOICONS = tango-icon-theme-0.8.90
WEBICONS = iconsjoy-webicons-3
JSSCRIPTS = anylinkcssmenu.js
NFDUMP = nfdump-1.6.9
FLOT = flot-0.5
JQUERYSPARKLINES=jquery.sparkline.uncompressed.2.1.js
# EasyXDM is different. Need to install every version available
EASYXDM = easyXDM-2.4.9.102 easyXDM-2.4.15.118
SHOWDOWN = showdown-0.9

ICOJOY4 = icojoy-webicons-4
ICOJOY4_TYPE = noshadow/standart/png/24x24
ICOJOY4_GENERATED = ${ICOJOY4}-greyscale

#
# Don't forget when updating ndoutils to also update installer/upgradedb_ndo.pl
# with any schema changes (and bin/db_runtime to increment nagios schema version)
# and commit
#
NDOUTILS = ndoutils-2-0
AUTOSSH = autossh-1.4a
HYPERGRAPH = hypergraph-0.6.3
NMIS = nmis-4.2.13
WMI = wmi-1.3.16

ifdef ROOT
DESTDIR=${ROOT}
ROOT = ""
endif

ifndef DESTDIR
DESTDIR = /
endif

# if building on debian then using fakeroot so carry on as normal
# if building anywhere else (i.e. rhel, solaris) have to check what user
# we are running as due to permissions
IN_FAKEROOT := $(shell echo $$DEB_BUILD_ARCH)
ifdef IN_FAKEROOT
 ROOT_USER=root
 NAGIOS_USER=nagios
 NAGIOS_GROUP=nagios
 NAGCMD_GROUP=nagcmd
else
 ifeq ($(shell id -un),root)
   ROOT_USER=root
   NAGIOS_USER=nagios
   NAGIOS_GROUP=nagios
   NAGCMD_GROUP=nagcmd
 else
  ifeq ($(shell id -un),nagios)
    ROOT_USER=nagios
    NAGIOS_USER=nagios
    NAGIOS_GROUP=nagios
    NAGCMD_GROUP=nagcmd
  else
    ROOT_USER=$(shell id -un)
    NAGIOS_USER=$(shell id -un)
    NAGIOS_GROUP=$(shell id -gn)
    NAGCMD_GROUP=$(shell id -gn)
  endif
 endif
endif

# NOTE: DESTDIR automatically applied; not needed here
MACOS_AGENT_DIR=/Applications/OpsviewAgent.app
NAGIOS_DIR = /usr/local/nagios
BIN_DIR = ${NAGIOS_DIR}/bin
ETC_DIR = ${NAGIOS_DIR}/etc
PLUGIN_DIR = ${NAGIOS_DIR}/libexec
WEB_DIR = ${NAGIOS_DIR}/share
CGIBIN_DIR = ${NAGIOS_DIR}/sbin
VAR_DIR = ${NAGIOS_DIR}/var
SNMP_DIR = ${NAGIOS_DIR}/snmp
LIB_DIR = ${NAGIOS_DIR}/lib
NMIS_DIR = ${NAGIOS_DIR}/nmis
# We use DESTDIR here, as it should be. Others will need migration
NAGVIS_DIR = ${DESTDIR}/${NAGIOS_DIR}/nagvis
CFLAGS =
LDFLAGS =

OS := $(shell uname -s)
SOLARCH =

ifeq ($(OS),SunOS)
	SOLARCH := $(shell isainfo -b)
	LDFLAGS =  -L/opt/csw/mysql5/lib/64 -L/opt/csw/lib -L/usr/sfw/lib -L/usr/local/ssl/lib -L/usr/local/mysql/lib/mysql -L/usr/lib -L/usr/local/lib -R/opt/csw/lib -R/usr/sfw/lib -R/usr/local/ssl/lib -R/usr/local/mysql/lib/mysql -R/usr/lib -R/usr/local/lib
	CFLAGS = -I/opt/csw/mysql5/include -I/opt/csw/include -I/usr/local/include -I/usr/local/include -I/usr/sfw/include -I/usr/local/rrdtool-1.2.19 -I/usr/local/mysql/include -I/usr/sfw/share/src/expat/lib -I/opt/sfw/include -I/usr/share/src/jpeg -I/usr/share/src/libpng -m${SOLARCH}
endif

# PATCH required for Solaris, since their patch command doesn't always work
# for our unified patches
PATCH = patch
INSTALL = ${NRPE}/install-sh

# If CUSTOMER is set, will check for customer patches
CUSTOMER =

OS_DISTRIBUTION := $(shell lsb_release -d)
OS_DISTRIBUTION := $(subst Description:,,$(OS_DISTRIBUTION))
OS_DISTRIBUTION := $(subst Distributor ID:,,$(OS_DISTRIBUTION)) # Solaris' format
OS_DISTRIBUTION := $(strip $(OS_DISTRIBUTION))

KERNEL_NAME := $(shell uname -s)
KERNEL_RELEASE := $(shell uname -r)

GENERATED = ${NAGIOS} ${NAGIOSPLUG} ${NRPE} ${SCRIPT} ${VALIDATION} ${NSCA} ${JSCAL} \
	${NDOUTILS} nrpe.cfg opsview-base.spec opsview-agent.spec version \
	allmibs.tar.gz ${CHECK_RADIUS_IH} ${AUTOSSH} ${HYPERGRAPH} ${NMIS} ${FABTABULOUS} \
	${NAGVIS} ${DATATABLES} ${TIMELINE} ${TANGOICONS} ${WEBICONS} ${ICOJOY4} ${FLOT} \
	${JQUERYSPARKLINES} ${EASYXDM} ${SHOWDOWN} ${WMI} ${NFDUMP}

# This is new style builds/installs. Makes it easier to compile and test local changes
BUILDS = ${NFDUMP}-build

all: ${GENERATED} ${BUILDS}

dev:
	$(MAKE) NAGIOSPLUG_CONFIGURE_PERL_MODULES=
	$(MAKE) all

install-fladmin:
	build-aux/fladmin -r ${DESTDIR} install filelist

# install-fladmin and post-test should always be last.
install: dirs ${NAGIOS}-install ${NAGIOSPLUG}-install ${NRPE}-install ${NSCA}-install \
	javascript-install ${NDOUTILS}-install install-mibs \
	${CHECK_RADIUS_IH}-install ${AUTOSSH}-install ${NMIS}-install nrpe.cfg-install \
	${FLOT}-install ${NFDUMP}-install ${WMI}-install \
	${ICOJOY4}-install ${FABTABULOUS}-install ${TANGOICONS}-install ${WEBICONS}-install ${NAGVIS}-install \
	easyxdm-install \
	${SHOWDOWN}-install \
	jsscripts-install install-fladmin post-test

install-dev:
	PERL5LIB="/usr/local/nagios/perl/lib/i486-linux-gnu-thread-multi:/usr/local/nagios/perl/lib:$PERL5LIB" \
	$(MAKE) install

version:
	perl -pe 's/%VERSION%/${VERSION}/g;' $@.in > $@

debpkg:
	cp debian/changelog.in debian/changelog
	VERSION=`cat version` && cd debian && build/mkdeb $$VERSION-1 ..

# Choose /tmp, but name specific to branch
# If choose within staging, lots of recursion occurs
solpkg:
	rm -fr /tmp/opsview-base
	mkdir /tmp/opsview-base
	mksolpkg -b -s /tmp/opsview-base

rpmpkg: tar
	sudo rpmbuild -ta --clean ../opsview-base-${VERSION}.tar.gz

allmibs.tar.gz:
	cd mibs && tar --gzip -cf ../allmibs.tar.gz *

post-test:
	perl -e '$$_="${DESTDIR}/${PLUGIN_DIR}/check_icmp"; -u $$_ || warn "WARNING: File not setuid (ok if packaging) : $$_\n"'
	perl -e '$$_="${DESTDIR}/${PLUGIN_DIR}/check_dhcp"; -u $$_ || warn "WARNING: File not setuid (ok if packaging) : $$_\n"'

# Need the test for NAGIOS_DIR so that can use soft links for dev systems
dirs: ${NRPE}
	test -d ${NAGIOS_DIR} || ${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${NAGIOS_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${BIN_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${ETC_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${PLUGIN_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${WEB_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${CGIBIN_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${VAR_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${SNMP_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${SNMP_DIR}/all
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${SNMP_DIR}/load
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${LIB_DIR}

echo-version:
	echo ${VERSION}

tar: opsview-base.spec
	if [ x${VERSION} = "x" ] ; then echo "Need version" ; false; fi
	$(MAKE) clean
	$(MAKE) opsview-base.spec version
	rm -f ../opsview-base-${VERSION}
	cd .. && ln -s opsview-base opsview-base-${VERSION}
	cd .. && tar -h -cf opsview-base-${VERSION}.tar --exclude=.svn --exclude=".git*" --exclude=windows_agent_pkg opsview-base-${VERSION}
	cd .. && gzip -f opsview-base-${VERSION}.tar
	cd .. && rm opsview-base-${VERSION}

agent-tar: opsview-agent.spec
	if [ x${VERSION} = "x" ] ; then echo "Need version" ; false; fi
	$(MAKE) clean
	$(MAKE) opsview-agent.spec version
	rm -f ../opsview-agent-${VERSION}
	cd .. && ln -s opsview-base opsview-agent-${VERSION}
	cd .. && tar -h -cf opsview-agent-${VERSION}.tar --exclude=.svn --exclude=".git*" opsview-agent-${VERSION}
	cd .. && gzip opsview-agent-${VERSION}.tar
	cd .. && rm opsview-agent-${VERSION}

agent ALTovagent: version ${NRPE} ${NAGIOSPLUG} nrpe.cfg

nrpe.cfg: ${NAGIOSPLUG} nrpe.cfg.in
	sed -e 's!/usr/local/nagios!${NAGIOS_DIR}!' nrpe.cfg.in > nrpe.cfg

${ICOJOY4}:
	unzip -q ${ICOJOY4}.zip -d ${ICOJOY4}

${ICOJOY4}-generated: ${ICOJOY4}
	mkdir ${ICOJOY4_GENERATED} 2>/dev/null || true
	for i in 03 04 07; do \
		convert ${ICOJOY4}/${ICOJOY4_TYPE}/001_$$i.png -channel RGBA -matte -colorspace gray -size 24x24 -resize 16x16 ${ICOJOY4_GENERATED}/001_$$i.png; \
	done
	convert ${ICOJOY4}/${ICOJOY4_TYPE}/001_05.png -size 24x24 -resize 16x16 ${ICOJOY4_GENERATED}/001_05.png

${ICOJOY4}-install:

icojoy4: ${ICOJOY4}

icojoy4-install: ${ICOJOY4}-install

showdown: ${SHOWDOWN}

${SHOWDOWN}:
	tar --gzip -xf ${SHOWDOWN}.tar.gz

${SHOWDOWN}-install:
	${INSTALL} -c -o ${NAGIOS_USER} -g ${NAGIOS_GROUP} -m 0644 ${SHOWDOWN}/compressed/showdown.js ${DESTDIR}/${WEB_DIR}/javascript/showdown.js

# Need to also check that cors/index.html matches with expected changes in opsview-web/root/restxdmxhr.html
easyxdm: ${EASYXDM}

${EASYXDM}:
	for i in ${EASYXDM}; do \
		mkdir $$i ;\
		cd $$i && unzip ../$$i.zip && cd .. ;\
	done

easyxdm-install:
	for i in ${EASYXDM}; do \
		j=`perl -e 'print lc(shift @ARGV)' $$i` ;\
		${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0755 ${DESTDIR}/${WEB_DIR}/javascript/$$j ;\
		${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0644 $$i/easyXDM.min.js ${DESTDIR}/${WEB_DIR}/javascript/$$j/easyXDM.js ;\
		${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0644 $$i/json2.js ${DESTDIR}/${WEB_DIR}/javascript/$$j/json2.js ;\
		${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0644 $$i/name.html ${DESTDIR}/${WEB_DIR}/javascript/$$j/name.html ;\
		[ -f $$i/easyxdm.swf ] && ${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0644 $$i/easyxdm.swf ${DESTDIR}/${WEB_DIR}/javascript/$$j/easyxdm.swf ;\
	done

jsscripts-install:
	for i in ${JSSCRIPTS} ; do \
		${INSTALL} -c -o ${NAGIOS_USER} -m 0644 $$i ${DESTDIR}/${WEB_DIR}/javascript ;\
	done

nrpe.cfg-install: nrpe.cfg
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0444 nrpe.cfg ${DESTDIR}/${ETC_DIR}/nrpe.cfg
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${ETC_DIR}/nrpe_local
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${PLUGIN_DIR}/nrpe_local

macosx-agent-tar:
	test -d /tmp/ROOT || mkdir /tmp/ROOT
	$(MAKE) agent NAGIOS_DIR=${MACOS_AGENT_DIR} DESTDIR=/tmp/ROOT
	sudo $(MAKE) install-agent NAGIOS_DIR=${MACOS_AGENT_DIR} DESTDIR=/tmp/ROOT
	sudo chown -R $$LOGNAME /tmp/ROOT # gets reset to root during packaging
	cp -r support_files/OpsviewAgent.app/* /tmp/ROOT/${MACOS_AGENT_DIR}/
	test -d /tmp/ROOT/Library/LaunchDaemons || mkdir -p /tmp/ROOT/Library/LaunchDaemons
	cp support_files/OpsviewAgent.plist /tmp/ROOT/Library/LaunchDaemons/org.opsview.agent.plist
	test -d /tmp/ROOT/${MACOS_AGENT_DIR}/Contents/MacOS || mkdir -p /tmp/ROOT/${MACOS_AGENT_DIR}/Contents/MacOS
	${INSTALL} -c -m 0555 ${ALTINITYPLUG}/check_macosx_memory /tmp/ROOT/${MACOS_AGENT_DIR}/libexec/check_memory
	${INSTALL} -c -m 0555 ${ALTINITYPLUG}/check_macosx_sensors /tmp/ROOT/${MACOS_AGENT_DIR}/libexec/check_sensors
	rm -f /tmp/ROOT/${MACOS_AGENT_DIR}/libexec/check_macos*

install-agent install-ALTovagent: ${NRPE} nrpe.cfg
	[ ! -f ${DESTDIR}/${NAGIOS_DIR} ] && ${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${NAGIOS_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0755 ${DESTDIR}/${BIN_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0755 ${DESTDIR}/${ETC_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0755 ${DESTDIR}/${ETC_DIR}/nrpe_local
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0755 ${DESTDIR}/${LIB_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${PLUGIN_DIR}
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${PLUGIN_DIR}/nrpe_local
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0755 ${DESTDIR}/${VAR_DIR}
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0555 ${NRPE}/src/nrpe ${DESTDIR}/${BIN_DIR}/nrpe
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0444 nrpe.cfg ${DESTDIR}/${ETC_DIR}/nrpe.cfg
	$(MAKE) DESTDIR=${DESTDIR} ${NAGIOSPLUG}-install
	$(MAKE) DESTDIR=${DESTDIR} nrpe.cfg-install

opsview-base.spec: opsview-base.spec.in
	perl -pe 's/%VERSION%/${VERSION}/g; s/%RELEASE%/${RELEASE}/g' opsview-base.spec.in > opsview-base.spec

opsview-agent.spec: opsview-agent.spec.in
	perl -pe 's/%VERSION%/${VERSION}/g; s/%RELEASE%/${RELEASE}/g' opsview-agent.spec.in > opsview-agent.spec


nagios: ${NAGIOS}

nagiosplug: ${NAGIOSPLUG}

nrpe: ${NRPE}

nsca: ${NSCA}

nagiosgraph: ${NAGIOSGRAPH}

ndoutils: ${NDOUTILS}

ndoutils-install: ${NDOUTILS}-install

autossh: ${AUTOSSH}

nmis: ${NMIS}

datatables: ${DATATABLES}

datatables-install: ${DATATABLES}-install

prototypextensions-install: ${PROTOTYPEXTENSIONS}-install

timeline-install: ${TIMELINE}-install

tangoicons-install: ${TANGOICONS}-install

webicons-install: ${WEBICONS}-install

flot-install: ${FLOT}-install

jquerysparklines-install: ${JQUERYSPARKLINES}-install

${SCRIPT}:
	gunzip -c ${SCRIPT}.tar.gz | tar -xf -
	cd ${SCRIPT} && patch -p1 < ../patches/scriptaculous_drag_problems_on_ie.patch
	cd ${SCRIPT} && patch -p1 < ../patches/scriptaculous_extention_domchanged_event.patch
	cd ${SCRIPT} && patch -p1 < ../patches/scriptaculous_prototype_fix_dispatchEvent_bug.patch
	# I think below is fixed now. The patch has been updated to apply, but it doesn't look like
	# there is anymore flicker on IE6 for the sidenav menus. Leave for now
	#cd ${SCRIPT} && patch -p1 < ../patches/scriptaculous_effects_blind_flicker_on_ie.patch
	# Fixes IE8's autocomplete box on servicechecks page going to wrong location
	# See https://prototype.lighthouseapp.com/projects/8886/tickets/618-getoffsetparent-returns-body-for-new-hidden-elements-in-ie8-final
	cd ${SCRIPT} && patch -p1 < ../patches/scriptaculous_prototype_fix_autocomplete_on_ie8.patch
	# Below is merged from prototype 1.9. This fixes validations on IE9 and IE10 (DE278). Need to upgrade/deprecate scriptaculous!
	cd ${SCRIPT}/lib && patch -p0 < ../../patches/scriptaculous_prototype_fix_ie9_event_stop.patch

validation: ${VALIDATION}

wmi: ${WMI}

nfdump: ${NFDUMP}

hypergraph: ${HYPERGRAPH}

hypergraph-install: ${HYPERGRAPH}-install

${VALIDATION}:
	gunzip -c ${VALIDATION}.tar.gz | tar -xf -
	cd ${VALIDATION} && patch -p1 < ../patches/validation_return_external_form_validation.patch
	cd ${VALIDATION} && patch -p1 < ../patches/validation_ignore_unnecessary_classnames.patch
	cd ${VALIDATION} && patch -p1 < ../patches/validation_stop_ie6_submit_on_exception.patch
	cd ${VALIDATION} && patch -p1 < ../patches/validation_extra_domains_on_email_addresses.patch
	cd ${VALIDATION} && patch -p1 < ../patches/validation_register_blur_handlers_when_dom_changes.patch
	cd ${VALIDATION} && patch -p0 < ../patches/validation_allow_classname_advice.patch

${FABTABULOUS}:
	gunzip -c ${FABTABULOUS}.tar.gz | tar -xf -
	cd ${FABTABULOUS} && patch -p1 < ../patches/fabtabulous_check_for_tabs.patch
	cd ${FABTABULOUS} && patch -p1 < ../patches/fabtabulous_validate_on_tab_switch.patch

PYTHON := $(shell which python)
export ZENHOME := $(subst /bin/python,,${PYTHON})
${WMI}:
ifndef ZENHOME
$(error ZENHOME is not set)
endif
	tar xjf ${WMI}.tar.bz2
	cd ${WMI} && patch -p1 < ../patches/wmi_fgrep.patch
	cd ${WMI} && make -f GNUmakefile

${NFDUMP}:
	tar xzf ${NFDUMP}.tar.gz
	cd ${NFDUMP} && patch -p1 < ../patches/nfdump-relative-time.patch
	cd ${NFDUMP} && patch -p1 < ../patches/nfdump-log-err-only.patch
	cd ${NFDUMP} && patch -p1 < ../patches/nfdump-file-list-prune.patch
	cd ${NFDUMP} && patch -p1 < ../patches/nfdump-utc-timezone-fix.patch
	cd ${NFDUMP} && patch -p1 < ../patches/nfdump-file-time-window.patch

${NFDUMP}-build: ${NFDUMP}
	cd ${NFDUMP} && ./configure && make

${NFDUMP}-install:
	for file in nfreplay nfdump nfcapd nfexpire nfanon; do \
		${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0500 ${NFDUMP}/bin/$$file ${DESTDIR}/${BIN_DIR}/$$file; \
	done

${HYPERGRAPH}:
	unzip -q ${HYPERGRAPH}.zip -d ${HYPERGRAPH}

${DATATABLES}:
	unzip -q ${DATATABLES}.zip -d ${DATATABLES}
	cd ${DATATABLES} && patch -p1 < ../patches/datatables_added_custom_sort_hook.patch

${TIMELINE}:
	unzip -q ${TIMELINE}.zip -d ${TIMELINE}
	cd ${TIMELINE} && patch -p1 < ../patches/timeline_IE_offsetwidth_bug_fix.patch
	cd ${TIMELINE} && patch -p1 < ../patches/timeline_turn_off_history.patch

${TANGOICONS}:
	gunzip -c ${TANGOICONS}.tar.gz | tar -xf -

${WEBICONS}:
	unzip -q ${WEBICONS}.zip -d ${WEBICONS}

${FLOT}:
	gunzip -c ${FLOT}.tar.gz | tar -xf -
	perl -i -pe 's/browser\.msie\)/browser.msie && typeof window.G_vmlCanvasManager=="object"\)/g' flot/jquery.flot.pack.js

${JQUERYSPARKLINES}:
	gunzip -c ${JQUERYSPARKLINES}.gz > ${JQUERYSPARKLINES}
	patch ${JQUERYSPARKLINES} < patches/sparkline_all_null_values.patch

${NAGIOS}:
	gunzip -c ${NAGIOS}.tar.gz | tar -xf -
	# Need to touch these files to stop a tap make rerunning it again - should be fixed in Nagios 3.2.2
	touch ${NAGIOS}/tap/aclocal.m4
	sleep 1
	find ${NAGIOS}/tap -name "Makefile.in" -exec touch {} \;
	sleep 1
	touch ${NAGIOS}/tap/configure
	# There are carriage returns in the docs, which affects the patching
	# cd ${NAGIOS}/html/docs && perl -i -pe 's/\r\n$$/\n/' *.html
	# cd ${NAGIOS}/html/stylesheets && perl -i -pe 's/\r\n$$/\n/' *.css
	# # Remove font-family, so inherits from common.css instead
	# cd ${NAGIOS}/html/stylesheets && perl -i -pe 's/\s?font-family:.*?;\s?//' *.css
	# # Remove .infoBox stuff, so inherits from common.css instead
	# cd ${NAGIOS}/html/stylesheets && perl -i -pe 's/^\.infoBox.*//' *.css
	# cd ${NAGIOS} && patch -p1 < ../patches/nagios_css_changes.patch
	# cd ${NAGIOS} && autoconf
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_statusmap_with_timeurl.patch
	# # TODO - low priority
	# #cd ${NAGIOS} && patch -p1 < ../patches/nagios_stalking_and_volatile_docs.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_slice_services_by_contacts.patch
	# #cd ${NAGIOS} && patch -p1 < ../patches/nagios_show_unhandleds_in_status_summary.patch	# This is not used for the moment
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_extinfo_icon_links_to_service_notes_and_validation.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_check_timeperiod_command.patch
	# #cd ${NAGIOS} && patch -p1 < ../patches/nagios_add_hosts_to_hostgroups_in_same_order.patch
	# # This new patch does part of the one above
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_handle_initial_state.patch
	# # Patch below stops host/service status being sent to DB. We make remove the patch so it is sent every startup
	# #cd ${NAGIOS} && patch -p1 < ../patches/nagios_stop_logging_retained_states_to_ndo.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_only_include_hosts_in_layer_list.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_store_cmd_cgi_submissions.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_store_cmd_cgi_submissions_opsview.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_notification_level.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_cgi_notes_icon_removed.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_remove_servicegroups_from_nagios_cgi_reports.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_increased_plugin_output.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_graph_link_from_status_list.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_host_up_hard.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_disable_image_installs.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_use_png_images.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_cgi_remove_javascript_helper_functions.patch
	# #cd ${NAGIOS} && cp ../patches/unlit-bulb.gif ./html/images/action.gif
	# #cd ${NAGIOS} && cp ../patches/comment.gif ./html/images/comment.gif
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_set_dependency_failure.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_is_active_with_renotification_interval.patch
	# # Disabling patch below. This seems to affect multiple callbacks
	# #cd ${NAGIOS} && patch -p1 < ../patches/nagios_retain_broker_module_order.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_save_processed_command.patch
	# # This is invalid - hold for a bit for now, but will be removed in future. Sticky acks are the way to go
	# #cd ${NAGIOS} && patch -p0 < ../patches/nagios_reset_notifications_for_critical.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_sticky_acks_default_off.patch
	# # Below because causes problems in distributed environment
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_remove_force_check.patch
	# cd ${NAGIOS}/cgi && patch -p0 < ../../patches/nagios_trends_nofixedsize.patch # No longer necessary?
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_trends_no_nagios_restarts.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_remove_unnecessary_status_update.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_extinfo_tidyups.patch
	# cd ${NAGIOS} && patch -p1 < ../patches/nagios_remove_body_common_css.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_allow_escaped_backslash_for_perfdata.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_host_processed_command.patch
	# # Below still to commit in Nagios trunk
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_conditional_debugging.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_fix_deletion_old_check_results.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_check_results_dir_sorted.patch
	# Think below is not necessary any more as there is a 30 second time limit added to reaping
	#cd ${NAGIOS} && patch -p1 < ../patches/nagios_reap_in_batches.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_ignore_check_options_across_retention.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_remove_3D_status_map_link.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_cmd_restyle.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_cgi_nagios_core_name.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_cgi_statuscgi_colours.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_time_jump_threshold.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_statedata_with_acks_downtime.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_addack_info_on_statechange.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_contactgrouplist_macro.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_no_web_images.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_layout.patch
	# Below required otherwise installs hang - fixed upstream differently
	#cd ${NAGIOS} && patch -p1 < ../patches/nagios_daemonise_worker_helpers.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_cgi_statuscgi_hostsenabled.patch
	# Patch below required as I think Solaris handles "struct comment" differently
	if [ $(KERNEL_NAME) = SunOS ] ; then \
	 	cp patches/ndoutils_sunos.h ${NAGIOS}/include/sunos.h ; \
	 	cp patches/ndoutils_sunos.c ${NAGIOS}/base/sunos.c ; \
	 	cd ${NAGIOS} && patch -p1 < ../patches/nagios_build_on_solaris.patch && \
	 	patch -p1 < ../patches/nagios_solaris_rlimit.patch && \
		patch -p1 < ../patches/nagios_solaris_compile_errors_for_comments_h.patch ; \
	fi
	# We patch IO broker to use select. epoll fails sometimes on centos5/rhel5, but this looks stable now
	# The test-iobroker used to have quite a few failures (or at least not as many successes)
	# but we stick to select for the moment
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_solaris_uses_select.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_check_iobroker_uses_select.patch
	# The following two should be fixed after 4.0.20130107
	#cd ${NAGIOS} && patch -p1 < ../patches/nagios_cgis_read_object_cache_location.patch
	# Following test update is not required
	#cd ${NAGIOS} && patch -p1 < ../patches/nagios_fix_cgi_tests.patch
	# Patch below should be available after 20130116
	# Updated to include nagios_code7_fix.patch and nagios_putenv_in_child_proc.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_macro_environents_in_command_definition.patch
	# Patch below replaced by slightly-different implementation upstream
	# cd ${NAGIOS} && patch -p0 < ../patches/nagios_fix_cgi_object_relationships.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_statusmap_remove_user_supplied_option.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_statusmap_reduce_nagios_process_text.patch
	# The event handler below is done in upstream code via 2683, but that doesn't seem to give the
	# proper timeout if event handler takes too long. We'll use our version until upstream works
	# Update: While this is fixed upstream, a subsequent patch has a dependency on it (compiles fail),
	# so we'll keep it for the moment
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_4_support_event_handlers.patch
	# Commit 2601 can be ignored for the moment
	# NOTE!!!!! When upgrading past 2601 (includes an API change) - need to check downtime.h is syncd with NDOutils, otherwise will get coredump in future
	# End bugfixes (till 2013-02-26)
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_reentrant_localtime.patch
	# The following two are related. The first was used for diagnosis and can probably come out. The 2nd may not be an issue anymore, but it doesn't hurt
	# (too much) to keep it
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_overcome_log_rotation_overwrites.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_fix_multiple_log_rotations.patch
	# Patch below to test that results from slaves get linefeeds converted correctly
	# Test with: perl -e 'print "opsview\tHTTP\t3\thelp\\nwith single \\\\ and\\n double \\\\\\\\ for all",$/' | send_nrd -c /usr/local/nagios/etc/send_nrd.cfg
	# Single backslashes are converted by Nagios into a double backslash in SERVICEOUTPUT, which then gets passed to NRD
	# NRD will just send data as is
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_convert_to_linefeeds_from_checkresults.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_allow_unescaped_semi_colons_for_check_commands_in_config_file.patch
	cd ${NAGIOS} && patch -p0 < ../patches/nagios_tilda_in_commands_execute_via_shell.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_accept_addrlen_fixes.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_output_limit_16k.patch
	# We take this away for the moment as killing jobs after timeout is implemented in Nagios Core now
	#cd ${NAGIOS} && patch -p1 < ../patches/nagios_worker_finish_timeout_commands_immediately.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_disable_nagios_updates.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_missing_host_variable_reset.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_max_concurrent_decrements.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_passive_host_svc_checks_and_host_svc_event_handlers.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_sync_retention_file.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_ignore_deleted_hosts_in_retention_dat.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_check_interval.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_bugfix_b81d828.patch
	# Patch below from http://tracker.nagios.org/view.php?id=470
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_tracker470_statusmap_host_pointers.patch
	# Below is a similar idea added to outages.cgi too
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_tracker470_outages_host_pointers.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_host_check_attempts_retained.patch
	# Patch below required as hard state changes not properly detected. Test is:
	# Set host to UP, cause it to fail. When goes into hard state, the time changed resets to time of hard state change
	# There is another problem where hard seems to go from 3/3 to 1/3 which seems wrong
	# but that's probably a bigger one to fry
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_host_hard_state_changes.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_centos5_rhel5_no_output_fix.patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios_avoid_swamping_log_when_killing_plugin.patch
	# Nagios utf-8 patch
	cd ${NAGIOS} && patch -p1 < ../patches/nagios-4.0.20130912.utf8.patch

	if [ $(KERNEL_NAME) = Linux ] ; then \
		cd ${NAGIOS} && CFLAGS="${CFLAGS}" ./configure --with-nagios-user=$(NAGIOS_USER) --with-nagios-group=$(NAGIOS_GROUP) --with-command-group=$(NAGIOS_GROUP) --with-cgiurl=/cgi-bin --with-htmurl=/ --enable-libtap ; \
	elif [ $(KERNEL_NAME) = Darwin ] ; then \
		cd ${NAGIOS} && CFLAGS="${CFLAGS}" ./configure --with-nagios-user=$(NAGIOS_USER) --with-nagios-group=$(NAGIOS_GROUP) --with-gd-inc=/sw/include --with-gd-lib=/sw/lib --with-command-group=nagios --with-cgiurl=/cgi-bin --with-htmurl=/ --enable-libtap ; \
	elif [ $(KERNEL_NAME) = SunOS ] ; then \
		cd ${NAGIOS} && CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" ./configure --with-gd-inc=/usr/local/include --with-gd-lib=/usr/local/lib --with-nagios-user=$(NAGIOS_USER) --with-nagios-group=$(NAGIOS_GROUP) --with-command-group=$(NAGIOS_GROUP) --with-cgiurl=/cgi-bin --with-htmurl=/ --enable-libtap ; \
	else \
		echo "Not supported OS"; false; \
	fi
	cd ${NAGIOS} && make all
	# We need to compile up the tap stuff, otherwise the wrong files are used. This is probably an issue
	# with our current Nagios tarball, but will not be too much hardship if compiled again
	# We don't bother running the tests as Nagios 4 have completely broken them and they are not maintained
	cd ${NAGIOS}/tap && make
	test -x ${NAGIOS}/cgi/statusmap.cgi || (echo "Statusmap not compiled" && exit 1)

# PATH added to configure to pick up sbin executables for Debian
${NAGIOSPLUG}:
	gunzip -c ${NAGIOSPLUG}.tar.gz | tar -xf -
	cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagiosplug_check_smart_help.patch
	#cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagiosplug_check_swap_solaris_fix.patch
	cp patches/nagiosplug_check_disk_smb.pl ${NAGIOSPLUG}/plugins-scripts/check_disk_smb.pl
	# Below fixed in 1.4.16 - but would will continue checking, see:
	# http://nagiosplug.git.sourceforge.net/git/gitweb.cgi?p=nagiosplug/nagiosplug;a=commit;h=cbc8a7f313c3e093165e544b4507539932c7f3e1
	# cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagiosplug_redundant_ssl_certificate_messages.patch
	# nagios-plugins tracker rt#3414894 for check_http patch
	cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagiosplug_check_http_connect_method.patch
	#cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagiosplug_lmstat_path.patch
	#cd ${NAGIOSPLUG} && aclocal -I gl/m4 -I m4 && autoconf -f
	# Have disabled below for the moment. Will be re-instated for single opsview-base work on ubuntu12
	#cd ${NAGIOSPLUG} && rm perlmods/*.tar.gz && cp ../patches/nagios-plugins-perlmods/*.tar.gz perlmods
	#cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagiosplug_withbuildplsupport.patch
	# Below added due to not being able to compile on Ubuntu12. This has an impact of using pm only for all agents on all platforms,
	# but this is okay
	cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagios_plugins_params_validate_noxs.patch
	cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagiosplug_check_snmp_override_perfstat_units.patch
	cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagiosplug_check_procs_add_negate_ereg.patch
	# checkout from git repository, see:
	# http://nagiosplug.sourceforge.net/developer-guidelines.html#DEVREQUIREMENTS
	cd ${NAGIOSPLUG} && ./tools/setup
	if [ $(KERNEL_NAME) = Linux ] ; then \
		cd ${NAGIOSPLUG} && PATH="/usr/bin:/usr/sbin:$$PATH" CFLAGS="${CFLAGS}" ./configure --with-mysql --with-nagios-user=$(NAGIOS_USER) --with-nagios-group=$(NAGIOS_GROUP) ${NAGIOSPLUG_CONFIGURE_PERL_MODULES} --localstatedir=/usr/local/nagios/var/plugins && make ; \
	elif [ $(KERNEL_NAME) = Darwin ] ; then \
		cd ${NAGIOSPLUG} && CFLAGS="${CFLAGS}" ./configure --with-mysql=/usr/local/mysql --with-nagios-user=nagios --with-nagios-group=nagios --prefix=${MACOS_AGENT_DIR} ${NAGIOSPLUG_CONFIGURE_PERL_MODULES} --localstatedir=/usr/local/nagios/var/plugins && make ; \
	elif [ $(KERNEL_NAME) = SunOS ] ; then \
		cd ${NAGIOSPLUG} && patch -p1 < ../patches/nagiosplug_check_ldap_solaris_fix.patch && cd ..; \
		cd ${NAGIOSPLUG} && CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" ./configure --with-nagios-user=$(NAGIOS_USER) --with-nagios-group=$(NAGIOS_GROUP) --with-libintl-prefix=/usr/lib ${NAGIOSPLUG_CONFIGURE_PERL_MODULES} --localstatedir=/usr/local/nagios/var/plugins && make ; \
	else \
		echo "Not supported OS"; \
	fi
	test -x ${NAGIOSPLUG}/plugins/check_ldap || (echo "check_ldap not compiled" && exit 1)

${NRPE}: OS_DISTRIBUTION := $(subst ;, ,$(OS_DISTRIBUTION))
${NRPE}:
	gunzip -c ${NRPE}.tar.gz | tar -xf -
	echo '#define OPSVIEW_VERSION_INFO "(OpsviewAgent $(VERSION); osname=$(KERNEL_NAME); osvers=$(KERNEL_RELEASE); desc=$(OS_DISTRIBUTION))"' >> ${NRPE}/include/common.h
	cd ${NRPE} && patch -p1 < ../patches/nrpe_solaris_log_facilities.patch
	cd ${NRPE} && patch -p1 < ../patches/nrpe_multiline.patch
	cd ${NRPE} && patch -p1 < ../patches/nrpe_remove_double_quotes_as_nasty.patch
	cd ${NRPE} && patch -p1 < ../patches/nrpe_autodiscover_ssldir.patch
	cd ${NRPE} && patch -p1 < ../patches/nrpe_remove_weak_ciphers.patch
	cd ${NRPE} && patch -p1 < ../patches/nrpe_show_system_info.patch
	# Below is required for NRPE 2.14 as autoconf fails otherwise
	cd ${NRPE} && patch -p1 < ../patches/nrpe_fix_autoconf.patch
	cd ${NRPE} && autoconf
	#make customer-hook MACRO=patch APP=nrpe DIR=${NRPE}
	if [ $(KERNEL_NAME) = SunOS ] ; then \
		cd ${NRPE} && patch -p1 < ../patches/nrpe_solaris_reduced_encryption.patch && CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" ./configure --enable-command-args --with-ssl=/usr/sfw && make ; \
    elif [ $(KERNEL_NAME) = Darwin ]; then \
        cd ${NRPE} && sed 's/libssl.so/libssl.dylib/' configure > configure.new && cp configure.new configure && LDFLAGS="${LDFLAGS}" CFLAGS="${CFLAGS}" ./configure --enable-command-args --prefix=${MACOS_AGENT_DIR} && make ;\
	else \
		cd ${NRPE} && LDFLAGS="${LDFLAGS}" ./configure --enable-command-args && make ; \
	fi


# Applies patches that are customer specific
# Not currently used
#customer-hook:
#	if [ x"${CUSTOMER}" != x ] ; then makefile=../customers/${CUSTOMER}/Makefile.${APP} && if [ -e $$makefile ] ; then make -f $$makefile ${MACRO} DIR=${DIR} PATCHDIR=$$PWD/../customers/${CUSTOMER}/patches; fi ; fi

${NSCA}:
	gunzip -c ${NSCA}.tar.gz | tar -xf -
	cd ${NSCA} && patch -p1 < ../patches/nsca_correct_packet_timestamp_core.patch
	cd ${NSCA} && patch -p1 < ../patches/nsca_remove_unnecessary_getpeername_call.patch
	cd ${NSCA} && patch -p1 < ../patches/nsca_improved_logging.patch
	cd ${NSCA} && patch -p1 < ../patches/nsca_missing_memory_tidyup.patch
	cd ${NSCA} && patch -p1 < ../patches/nsca_ignore_bad_connection.patch
	# Don't use patch below just yet - one for future
	#cd ${NSCA} && patch -p1 < ../patches/nsca_limits.patch
	cd ${NSCA} && patch -p1 < ../patches/nsca_aggregate_writes_to_alternate.patch
	cp patches/nsca_alternate.t ${NSCA}/nsca_tests/alternate.t
	cp patches/nsca_aggregate.cfg ${NSCA}/nsca_tests/nsca_aggregate.cfg
	cd ${NSCA} && CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}" ./configure --with-nsca-user=$(NAGIOS_USER) --with-nsca-grp=$(NAGIOS_GROUP)
	grep "HAVE_LIBMCRYPT" ${NSCA}/src/Makefile > /dev/null
	cd ${NSCA} && make
	cd ${NSCA} && perl -i -pe 's/^((de|en)cryption_method)=\d+\s*$$/$$1=2/' sample-config/nsca.cfg sample-config/send_nsca.cfg
	strip ${NSCA}/src/nsca ${NSCA}/src/send_nsca

${NMIS}:
	gunzip -c ${NMIS}.tar.gz | tar -xf -
	rm ${NMIS}/SNMP_Simple_NMIS.tar.gz
	rm -r ${NMIS}/contrib
	rm ${NMIS}/conf/apache-sample.conf
	utils/prune_nmis_configs -d ${NMIS}/conf contacts-sample.csv escalation-sample.csv locations-sample.csv logs-sample.csv nodes-sample.csv master-sample.csv slave-example.csv slaves-example.csv
	cp patches/nmis_detail.pm ${NMIS}/lib/detail.pm
	#cp patches/nmis_nmis.pl ${NMIS}/bin/nmis.pl	# Ignore for now because of patches to stop blank ifAlias being ignored for collection
	cp patches/nmis_nmiscgi.pl ${NMIS}/cgi-bin/nmiscgi.pl
	cp patches/nmis_func.pm ${NMIS}/lib/func.pm
	cp patches/nmis_NMIS.pm ${NMIS}/lib/NMIS.pm
	cp patches/nmis_connect.pl ${NMIS}/cgi-bin/connect.pl
	cd ${NMIS} && patch -p1 < ../patches/nmis_masterslave_allow_path_rsync.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_master_bind_to_localhost.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_juniper_support.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_rsyncd_removed_on_slave.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_find_interfaces_on_master.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_traffic_page.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_delete_single_node_on_slaves.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_reports_without_script_name.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_run_reports.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_opsview_link.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_pix7+_cpu_graphing.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_pix-conn_typo.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_disable_all_events.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_support_for_netscreen_alteons_foundrys_ellacoya_ciscocss.patch
	cd ${NMIS} && patch -p1 < ../patches/nmis_ellacoya_stats_collection.patch
	cd ${NMIS} && patch cgi-bin/admin.pl < ../patches/nmis_block_bad_shell_characters.patch
	cd ${NMIS} && patch cgi-bin/reports.pl < ../patches/nmis_report_top10.patch
	cp patches/nmis_juniper.oid ${NMIS}/mibs/juniper.oid
	cp patches/nmis_netscreen.oid ${NMIS}/mibs/netscreen.oid
	cp patches/nmis_arrowpoint.oid ${NMIS}/mibs/arrowpoint.oid
	cp patches/nmis_ellacoya.oid ${NMIS}/mibs/ellacoya.oid
	cp patches/nmis_alteon.oid ${NMIS}/mibs/alteon.oid
	perl -pe 's%^<nmis_base>=.*%<nmis_base>=/usr/local/nagios/nmis%; s/^username=/username=nagios/; s/dash_title=.*/dash_title=NMIS via Opsview/; s%^<cgi_url_base>=.*%<cgi_url_base>=/cgi-nmis%; s%^<url_base>=.*%<url_base>=/static/nmis%; s/conf_count=.*/conf_count=249/; s/^master_dash=.*/master_dash=true/; s/^master=.*/master=true/; s/^hc_model=.*/hc_model=6509|cisco7609|cisco7606|jnxProductNameM10i|juniErx1440|juniE320|ellacoya|catalyst35|catalyst37|wsc6006sysID|cisco7204VXR|netscreenISG/; s/^full_mib=.*/full_mib=nmis_mibs.oid,a3com.oid,dell.oid,juniper.oid,ellacoya.oid,alteon.oid,netscreen.oid,arrowpoint.oid,CISCO-PRODUCTS-MIB.oid,foundry.oid/; s/^master_report=.*/master_report=true/; s/^int_stats=.*/int_stats=ethernetCsmacd|sdlc|propPointToPointSerial|frameRelay|e10a100BaseTX|e100BaseFX|e1000BaseSX|e1000BaseLH|pos|l2vlan/; ' ${NMIS}/conf/nmis-sample.conf > ${NMIS}/conf/nmis.conf
	rm ${NMIS}/conf/nmis-sample.conf
	cd ${NMIS} && patch -p1 < ../patches/nmis_configurable_default_ifAlias.patch

${NMIS}-install: ${NMIS}
	[ ! -d ${DESTDIR}/${NMIS_DIR} ] && mkdir ${DESTDIR}/${NMIS_DIR} || true
	chown $(NAGIOS_USER):$(NAGIOS_GROUP) ${DESTDIR}/${NMIS_DIR}
	chmod g+ws ${DESTDIR}/${NMIS_DIR}
	cp -r ${NMIS}/* ${DESTDIR}/${NMIS_DIR}
	chown -R $(NAGIOS_USER):$(NAGIOS_GROUP) ${DESTDIR}/${NMIS_DIR}
	chmod -R 0775 ${DESTDIR}/${NMIS_DIR}

${JSCAL}:
	tar --gzip -xf ${JSCAL}.tar.gz

${NAGIOSGRAPH}:
	tar --gzip -xf ${NAGIOSGRAPH}.tar.gz
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_using_perl_lib.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_procs.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_nounits.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_time_in_url.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_use_minicpan.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_specify_set_of_colours.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_html4_validation_for_strong_tag.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_line1.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_trap_parse_errors.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_footer_id_change.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_map_local.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_losspct_set_unknown_to_100.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_map_check_ping_losspct.patch
	cd ${NAGIOSGRAPH} && patch -p1 < ../patches/nagiosgraph_insert_pl_rrd_simple.patch
	cat patches/nagiosgraph_map_extras >> ${NAGIOSGRAPH}/map

# -fPIC required for x64 compiles
# TODO: Hosts and Services need to list all the contacts associated
# and it looks like ndoutils-1.4b7 has removed this code, though is in 1.4b3
${NDOUTILS}:
	tar --gzip -xf ${NDOUTILS}.tar.gz
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_issue_commands.patch # Not needed — for Nagios 2 only
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_notification_level.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_better_mysql_detection.1.4b7.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_check_timeperiod_command.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_trim_externalcommands_table.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_reduce_housekeep_cycle.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_stop_logging_retained_states_to_ndo.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_show_mysql_error.patch
	# #cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_from_later_versions.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_amend_syslog_levels.patch
	# # We ignore this patch because host failures are similar to service failures in Nagios 3
	# #cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_rotate_sink_on_host_failure.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_notification_number.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_setup_sink_rotation_event.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_solaris_eintr_in_accept.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_remove_multiple_children.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_retry_on_soft_read_errors.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_use_sigaction_for_child_handler.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_removed_message_queues.patch
	# # removed as causes a failure in distributed setups (access rights incorrect)
	# #cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_remove_distprofiles.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_file2sock_larger_write_blocks.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_multi_valued_inserts.patch
	# # This is not necessary in ndoutils1.4b7 as it logs contactgroups, not individual contacts
	# #cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_remove_duplicate_host_contacts.patch
	# # Credit to Wolfgang Powisch for patch below (from nagios-devel mailing list)
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_rotate_command_fix.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_set_connection_to_utc.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_remove_configfiledump.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_truncate_tables.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_retry_instance_name.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_no_unique_key_on_servicechecks.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_do_not_reset_downtimes_on_nagios_reload.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_do_not_clear_downtime_table.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_save_processed_command.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_larger_buffer_size.patch
	# mkdir ${NDOUTILS}/m4
	# cp patches/ndoutils_np_mysqlclient.m4 ${NDOUTILS}/m4/np_mysqlclient.m4
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_long_plugin_output.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_database_long_output_removed.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_sync_nagios_4_object.h.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_pk.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_no_unique_key_on_hostchecks.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_downtimes_do_not_update_start_times.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_hide_db_connection_messages.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_fix_memory_leak_multiple_hellos.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_statedata_with_acks_downtime.patch
	# cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_performance_improvement_for_object_lookup.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_with_fixed_multiple_newlines_at_end.patch
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_fix_nagvis_issue_with_programstatus.patch
	# cd ${NDOUTILS} && aclocal -I m4 && autoconf
	# #cp patches/ndoutils_upgradedb.pl ${NDOUTILS}/db/upgradedb.pl
	# #cp patches/ndoutils_mysql-upgrade-1.4b3.sql ${NDOUTILS}/db/mysql-upgrade-1.4b3.sql
	if [ $(KERNEL_NAME) = SunOS ] ; then \
	 	cp patches/ndoutils_sunos.h ${NDOUTILS}/include/sunos.h ; \
	 	cp patches/ndoutils_sunos.c ${NDOUTILS}/src/sunos.c ; \
	 	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_build_on_solaris.patch && \
		cd include/nagios-4x && patch -p2 < ../../../patches/nagios_solaris_compile_errors_for_comments_h.patch ;\
	fi
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_increase_max_buflen.patch
	# Patch below to remove 125= from ndo.dat as Opsview just uses the output field
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_remove_longoutput_from_ndodat.patch
	# if [ $(KERNEL_NAME) = Darwin ] ; then \
	# 	extra_opts="--with-mysql=/usr/local/mysql"; \
	# fi;
	cd ${NDOUTILS} && CFLAGS="-fPIC ${CFLAGS}" LDFLAGS="${LDFLAGS}" ./configure --with-ndo2db-user=$(NAGIOS_USER) --with-ndo2db-group=$(NAGIOS_GROUP) --disable-pgsql $$extra_opts
	@echo "Checking that mysql has been found"
	grep lib_mysqlclient ${NDOUTILS}/config.log | grep yes > /dev/null
	cd ${NDOUTILS} && make
	# perl -pi -e 's/DEFAULT CHARSET=ascii //' ${NDOUTILS}/db/mysql.sql
	# # This patch is so ndoutils' create script creates the same schema as our upgrades to
	cd ${NDOUTILS} && patch -p1 < ../patches/ndoutils_synchronise_mysql_create.patch
	cd ${NDOUTILS} && cp ../patches/altinity_distributed_commands.c src
	cd ${NDOUTILS} && cp ../patches/altinity_distributed_commands.h include
	cd ${NDOUTILS} && ln ../patches/altinity_set_initial_state.c src
	cd ${NDOUTILS} && ln ../patches/altinity_set_initial_state.h include
	cd ${NDOUTILS} && ln ../patches/opsview_distributed_notifications.c src
	cd ${NDOUTILS} && ln ../patches/opsview_distributed_notifications.h include
	cd ${NDOUTILS} && ln ../patches/opsview_notificationprofiles.c src
	cd ${NDOUTILS} && ln ../patches/opsview_notificationprofiles.h include
	cd ${NDOUTILS} && patch -p1 < ../patches/altinity_distributed_commands_Makefile.patch
	cd ${NDOUTILS}/src && make altinity_distributed_commands.o
	cd ${NDOUTILS}/src && make altinity_set_initial_state.o
	cp ${NAGIOS}/tap/src/tap.h ${NDOUTILS}/src
	cd ${NDOUTILS} && ln ../patches/test_distributed_notifications.c src
	cd ${NDOUTILS} && ln ../patches/test_notificationprofiles.c src
	cd ${NDOUTILS}/src && make opsview_distributed_notifications.o && make NAGIOS=$(NAGIOS) test_distributed_notifications
	cd ${NDOUTILS}/src && make opsview_notificationprofiles.o && make NAGIOS=$(NAGIOS) test_notificationprofiles
	cp ${NAGIOS}/t-tap/test_each.t ${NDOUTILS}/src
	cd ${NDOUTILS}/src && HARNESS_PERL=./test_each.t perl -MTest::Harness -e '$$Test::Harness::switches=""; runtests(map { "./$$_" } @ARGV)' test_notificationprofiles test_distributed_notifications

nagvis: ${NAGVIS}

${NAGVIS}:
	tar --gzip -xf ${NAGVIS}.tar.gz
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_config.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_tighten_permissions
	# We temporarily remove this as changes will be around this area
	#cd ${NAGVIS} && patch -p1 < ../patches/nagvis_redirect_host_to_opsview.patch
	# Split below out from above
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_add_opsviewbase.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_force_utc.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_remove_shape_management.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_add_opsview_base_macro.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_hostgroup_id.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_use_opsview_links.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_use_opsview_tables.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_remove_display_errors.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_no_logo.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_opsview_style.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_remove_favicon.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_automap_iconset.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_opsview_iconset.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_default_timezone.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_custom_css.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_firefox_6.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_remove_deprecated_display_errors.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_config_url_target.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_msie10.patch
	cd ${NAGVIS} && patch -p1 < ../patches/nagvis_htmlentities.patch
	# TODO update patches that work but with some fuzz
	find ${NAGVIS} -name "*.orig" -exec rm {} \;
	cp patches/nagvis/opsview.cfg ${NAGVIS}/etc/maps/
	cp patches/nagvis/iconsets/opsview*.png ${NAGVIS}/nagvis/images/iconsets/
	cp patches/nagvis/opsview_system.jpg ${NAGVIS}/nagvis/images/maps/

${NAGVIS_DIR}:
	mkdir -p ${NAGVIS_DIR}

${NAGVIS}-install: ${NAGVIS_DIR}
	# Bit of magic below: install nagvis files and change permissions. Can't use chown -R as some files may already belong to apache user
	( tar -C ${NAGVIS} --exclude=".git*" --exclude=demo*.cfg -cf - . | (cd ${NAGVIS_DIR} && tar -xvf - | xargs chown $(NAGIOS_USER):$(NAGIOS_GROUP))  )
	chmod 2775 ${NAGVIS_DIR}/nagvis/images/maps ${NAGVIS_DIR}/nagvis/images/shapes
	chgrp $(NAGCMD_GROUP) ${NAGVIS_DIR}/nagvis/images/maps ${NAGVIS_DIR}/nagvis/images/shapes
	chgrp $(NAGCMD_GROUP) ${NAGVIS_DIR}/nagvis/images/maps/nagvis-demo.png ${NAGVIS_DIR}/nagvis/images/maps/demo_background.png ${NAGVIS_DIR}/nagvis/images/maps/opsview_system.jpg
	chmod 664 ${NAGVIS_DIR}/nagvis/images/maps/nagvis-demo.png ${NAGVIS_DIR}/nagvis/images/maps/demo_background.png ${NAGVIS_DIR}/nagvis/images/maps/opsview_system.jpg
	chmod 2775 ${NAGVIS_DIR}/etc/maps
	chgrp $(NAGCMD_GROUP) ${NAGVIS_DIR}/etc/maps
	chgrp $(NAGCMD_GROUP) ${NAGVIS_DIR}/etc/maps/__automap.cfg
	chmod 664 ${NAGVIS_DIR}/etc/maps/__automap.cfg
	chgrp $(NAGCMD_GROUP) ${NAGVIS_DIR}/etc/maps/opsview.cfg
	chmod 664 ${NAGVIS_DIR}/etc/maps/opsview.cfg
	chgrp $(NAGCMD_GROUP) ${NAGVIS_DIR}/var
	chmod 2775 ${NAGVIS_DIR}/var

install-mibs: allmibs.tar.gz
	tar --gzip -xf allmibs.tar.gz -C ${DESTDIR}/${SNMP_DIR}/all
	chown -R $(NAGIOS_USER):$(NAGIOS_GROUP) ${DESTDIR}/${SNMP_DIR}/all/

${CHECK_RADIUS_IH}:
	tar --gzip -xf ${CHECK_RADIUS_IH}.tgz
	cd ${CHECK_RADIUS_IH} && patch -p1 < ../patches/check_radius_ih_makefile.patch
	cd ${CHECK_RADIUS_IH} && patch -p1 < ../patches/check_radius_ih_lucid_fixes.patch
	cd ${CHECK_RADIUS_IH} && ./configure --exec-prefix=${PLUGIN_DIR} && make

${AUTOSSH}:
	tar --gzip -xf ${AUTOSSH}.tar.gz
	cd ${AUTOSSH} && ./configure && make

${AUTOSSH}-install:
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0755 ${AUTOSSH}/autossh ${DESTDIR}/${BIN_DIR}/autossh

javascript-install: javascript-pre-install ${SCRIPT}-install ${VALIDATION}-install ${JSCAL}-install ${HYPERGRAPH}-install ${DATATABLES}-install ${PROTOTYPEXTENSIONS}-install ${TIMELINE}-install ${JQUERYSPARKLINES}-install javascript-post-install

${NAGIOS}-install:
	cd ${NAGIOS} && make install prefix=${NAGIOS_DIR} && make install-commandmode prefix=${NAGIOS_DIR}
	cd ${NAGIOS}/html && make install prefix=${NAGIOS_DIR}
	# Nagios 4 appears to not install these logo images anymore - we set them here
	cp ${NAGIOS}/html/images/logos/* ${DESTDIR}${NAGIOS_DIR}/share/images/logos
	# Delete some rss files that are not required
	rm -rf ${DESTDIR}/${NAGIOS_DIR}/share/rss-*

${NAGIOSPLUG}-install:
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${PLUGIN_DIR}
	cd ${NAGIOSPLUG} && make install-strip prefix=${NAGIOS_DIR}
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 755 ${NAGIOSPLUG}/contrib/check_smart.pl ${DESTDIR}/${PLUGIN_DIR}/check_smart
	${INSTALL} -c -o $(ROOT_USER) -g $(NAGIOS_GROUP) -m 4550 ${NAGIOSPLUG}/plugins-root/check_icmp ${DESTDIR}/${PLUGIN_DIR}/check_icmp
	${INSTALL} -c -o $(ROOT_USER) -g $(NAGIOS_GROUP) -m 4550 ${NAGIOSPLUG}/plugins-root/check_dhcp ${DESTDIR}/${PLUGIN_DIR}/check_dhcp
	if [ -f ${NAGIOSPLUG}/plugins-root/pst3 ]; then \
		${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 755 ${NAGIOSPLUG}/plugins-root/pst3 ${DESTDIR}/${PLUGIN_DIR}/pst3 ;\
	fi
	if [ $(KERNEL_NAME) = SunOS ] ; then \
        ${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 755 ${ALTINITYPLUG}/check_memory_solaris ${DESTDIR}/${PLUGIN_DIR}/check_memory ;\
    else \
        ${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 755 ${ALTINITYPLUG}/check_memory ${DESTDIR}/${PLUGIN_DIR}/check_memory ;\
    fi
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 755 ${ALTINITYPLUG}/check_dir_age ${DESTDIR}/${PLUGIN_DIR}/check_dir_age
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 755 ${ALTINITYPLUG}/check_postgres ${DESTDIR}/${PLUGIN_DIR}/check_postgres
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 755 ${ALTINITYPLUG}/check_time_skew ${DESTDIR}/${PLUGIN_DIR}/check_time_skew
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 755 ${ALTINITYPLUG}/check_raid ${DESTDIR}/${PLUGIN_DIR}/check_raid
	test -h ${DESTDIR}/${PLUGIN_DIR}/check_host || ( cd ${DESTDIR}/${PLUGIN_DIR} && ln -s check_icmp check_host )

${NRPE}-install:
	cd ${NRPE}/src && ../install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0511 check_nrpe ${DESTDIR}/${PLUGIN_DIR}/check_nrpe
	cd ${NRPE}/src && ../install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0511 nrpe ${DESTDIR}/${BIN_DIR}/nrpe

${NSCA}-install:
	${NSCA}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0500 ${NSCA}/src/nsca ${DESTDIR}/${BIN_DIR}/nsca
	${NSCA}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0500 ${NSCA}/src/send_nsca ${DESTDIR}/${BIN_DIR}/send_nsca

${NAGIOSGRAPH}-install:
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0640 ${NAGIOSGRAPH}/nagiosgraph.conf ${DESTDIR}/${ETC_DIR}/nagiosgraph.conf
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0500 ${NAGIOSGRAPH}/insert.pl ${DESTDIR}/${BIN_DIR}/insert.pl
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0554 ${NAGIOSGRAPH}/show.cgi ${DESTDIR}/${CGIBIN_DIR}/show.cgi
	${INSTALL} -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0440 ${NAGIOSGRAPH}/map ${DESTDIR}/${ETC_DIR}/map
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 2750 ${DESTDIR}/${VAR_DIR}/rrd
	${INSTALL} -d -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0775 ${DESTDIR}/${VAR_DIR}/log
	touch ${DESTDIR}/${VAR_DIR}/log/nagiosgraph.log && chmod 660 ${DESTDIR}/${VAR_DIR}/log/nagiosgraph.log && chown $(NAGIOS_USER):$(NAGIOS_GROUP) ${DESTDIR}/${VAR_DIR}/log/nagiosgraph.log

javascript-pre-install:
	[ ! -d ${DESTDIR}/${WEB_DIR}/javascript ] && mkdir ${DESTDIR}/${WEB_DIR}/javascript && chown ${NAGIOS_USER} ${DESTDIR}/${WEB_DIR}/javascript || true
	[ ! -d ${DESTDIR}/${WEB_DIR}/xml ] && mkdir ${DESTDIR}/${WEB_DIR}/xml && chown ${NAGIOS_USER} ${DESTDIR}/${WEB_DIR}/xml || true

${SCRIPT}-install:
	cd ${SCRIPT}/lib && ../../${INSTALL} -c -o ${NAGIOS_USER} -m 0444 prototype.js ${DESTDIR}/${WEB_DIR}/javascript/prototype.js
	for i in scriptaculous.js builder.js effects.js dragdrop.js controls.js slider.js sound.js ; do \
		${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${SCRIPT}/src/$$i ${DESTDIR}/${WEB_DIR}/javascript/$$i ;\
	done

${VALIDATION}-install:
	for i in validation.js ; do \
		${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${VALIDATION}/$$i ${DESTDIR}/${WEB_DIR}/javascript ;\
	done

${FABTABULOUS}-install:
	for i in fabtabulous.js ; do \
		${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${FABTABULOUS}/$$i ${DESTDIR}/${WEB_DIR}/javascript ;\
	done

${WMI}-install:
	${INSTALL} -c -o ${NAGIOS_USER} -m 0555 ${WMI}/Samba/source/bin/wmic ${DESTDIR}/${BIN_DIR}

${HYPERGRAPH}-install:
	${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${HYPERGRAPH}/samples/hexplorer/hyperapplet.jar ${DESTDIR}/${WEB_DIR}/javascript
	${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${HYPERGRAPH}/samples/hexplorer/GraphXML.dtd ${DESTDIR}/${WEB_DIR}/xml

${DATATABLES}-install:
	${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${DATATABLES}/${DATATABLESMAJOR}/media/js/jquery.js ${DESTDIR}/${WEB_DIR}/javascript
	${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${DATATABLES}/${DATATABLESMAJOR}/media/js/jquery.dataTables.min.js ${DESTDIR}/${WEB_DIR}/javascript/jquery.dataTables.js
	${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${DATATABLES}/${DATATABLESMAJOR}/media/css/demos.css ${DESTDIR}/${WEB_DIR}/stylesheets/dataTables.css
	for i in ${DATATABLES}/${DATATABLESMAJOR}/media/images/* ; do \
		${INSTALL} -c -o ${NAGIOS_USER} -m 0444 $$i ${DESTDIR}/${WEB_DIR}/images ;\
	done

${PROTOTYPEXTENSIONS}-install:
	${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ./${PROTOTYPEXTENSIONS}.js ${DESTDIR}/${WEB_DIR}/javascript/prototypextensions.js

${TIMELINE}-install:
	[ ! -d ${DESTDIR}/${WEB_DIR}/javascript/timeline ] && mkdir ${DESTDIR}/${WEB_DIR}/javascript/timeline || true
	cp -r ${TIMELINE}/timeline_${TIMELINEVER}/* ${DESTDIR}/${WEB_DIR}/javascript/timeline/
	( tar -C ${TIMELINE}/timeline_${TIMELINEVER} --exclude=".git*" -cf - . | (cd ${DESTDIR}/${WEB_DIR}/javascript/timeline && tar -xvf - | xargs chown $(NAGIOS_USER)) )

# These are in opsview-images, due for refresh
${TANGOICONS}-install:
	#${INSTALL} -c -m 0444 ${TANGOICONS}/16x16/categories/applications-internet.png ${DESTDIR}/${WEB_DIR}/images/link-icon.png
	#${INSTALL} -c -m 0444 ${TANGOICONS}/16x16/categories/preferences-system.png ${DESTDIR}/${WEB_DIR}/images/settings-icon.png
	#${INSTALL} -c -m 0444 ${TANGOICONS}/16x16/actions/view-fullscreen.png ${DESTDIR}/${WEB_DIR}/images/rescale-axis.png
	#${INSTALL} -c -m 0444 ${TANGOICONS}/16x16/actions/edit-undo.png ${DESTDIR}/${WEB_DIR}/images/edit-undo.png
	#${INSTALL} -c -m 0444 ${TANGOICONS}/16x16/mimetypes/x-office-spreadsheet.png ${DESTDIR}/${WEB_DIR}/images/thresholds-off.png
	#${INSTALL} -c -m 0444 ${TANGOICONS}/16x16/mimetypes/x-office-spreadsheet-template.png ${DESTDIR}/${WEB_DIR}/images/thresholds-on.png

${WEBICONS}-install:

${FLOT}-install:
	${INSTALL} -c -o ${NAGIOS_USER} -m 0444 flot/jquery.flot.pack.js ${DESTDIR}/${WEB_DIR}/javascript/jquery.flot.js
	${INSTALL} -c -o ${NAGIOS_USER} -m 0444 flot/excanvas.pack.js ${DESTDIR}/${WEB_DIR}/javascript/excanvas.js
	# Use below for flot-0.7
	#${INSTALL} -c -o ${NAGIOS_USER} -m 0444 flot/jquery.flot.min.js ${DESTDIR}/${WEB_DIR}/javascript/jquery.flot.js
	#${INSTALL} -c -o ${NAGIOS_USER} -m 0444 flot/excanvas.min.js ${DESTDIR}/${WEB_DIR}/javascript/excanvas.js

${JQUERYSPARKLINES}-install:
	${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${JQUERYSPARKLINES} ${DESTDIR}/${WEB_DIR}/javascript/jquery.sparkline.js

${JSCAL}-install:
	for i in calendar.js calendar-setup.js lang/calendar-en.js ; do \
		${INSTALL} -c -o ${NAGIOS_USER} -m 0444 ${JSCAL}/$$i ${DESTDIR}/${WEB_DIR}/javascript ;\
	done
	cp -pr ${JSCAL}/skins ${DESTDIR}/${WEB_DIR}/stylesheets

javascript-post-install:
	#find ${DESTDIR}/${WEB_DIR}/javascript ${DESTDIR}/${WEB_DIR}/xml | grep -v .svn | xargs chown ${NAGIOS_USER}

${NDOUTILS}-install:
	# We use the mysql script from ndoutils 1.4b7 as Opsview will maintain this in future
	${NDOUTILS}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0444 patches/ndoutils_mysql_1.4b7.sql ${DESTDIR}/${BIN_DIR}/ndo_mysql.sql
	${NDOUTILS}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0400 ${NDOUTILS}/src/ndomod-4x.o ${DESTDIR}/${BIN_DIR}/ndomod.o
	${NDOUTILS}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0500 ${NDOUTILS}/src/ndo2db-4x ${DESTDIR}/${BIN_DIR}/ndo2db
	${NDOUTILS}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0500 ${NDOUTILS}/src/file2sock ${DESTDIR}/${BIN_DIR}/file2sock
	${NDOUTILS}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0400 ${NDOUTILS}/src/altinity_distributed_commands.o ${DESTDIR}/${BIN_DIR}/altinity_distributed_commands.o
	${NDOUTILS}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0400 ${NDOUTILS}/src/altinity_set_initial_state.o ${DESTDIR}/${BIN_DIR}/altinity_set_initial_state.o
	${NDOUTILS}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0400 ${NDOUTILS}/src/opsview_distributed_notifications.o ${DESTDIR}/${BIN_DIR}/opsview_distributed_notifications.o
	${NDOUTILS}/install-sh -c -o $(NAGIOS_USER) -g $(NAGIOS_GROUP) -m 0400 ${NDOUTILS}/src/opsview_notificationprofiles.o ${DESTDIR}/${BIN_DIR}/opsview_notificationprofiles.o

${CHECK_RADIUS_IH}-install:
	cd ${CHECK_RADIUS_IH} && make install

clean:
	rm -fr ${GENERATED} opsview-base-*.tar.gz

uninstall:
	build-aux/fladmin -r ${DESTDIR} uninstall filelist

# We remove this so that the version file is only generated once
#.PHONY: version
# I think the debpkg is required to ensure that the package is created correctly
.PHONY: debpkg
