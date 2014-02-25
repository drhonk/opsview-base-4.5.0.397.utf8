# Makefile for Solaris agent package

PKGDIR=/pkgs/ALTnrpe

install:
	cp nrpe-startup /etc/init.d/nrpe
	rm -f /etc/rc3.d/S99nrpe
	cd /etc/rc3.d && ln -s ../init.d/nrpe S99nrpe
	[ -d ${PKGDIR} ] || install -d ${PKGDIR}
	install -f ${PKGDIR} extrafiles
	install -f ${PKGDIR} postinstall
	install -f ${PKGDIR} preinstall
	install -f ${PKGDIR} preremove
	install -f ${PKGDIR} prototype

pkg: install
	cd /pkgs && ./mkpkg.sh ALTnrpe /usr/local/nagios
	
