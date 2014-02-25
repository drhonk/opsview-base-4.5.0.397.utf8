#! /bin/sh
#

### BEGIN INIT INFO
# Provides:          opsview-agent
# Required-Start:    $local_fs $remote_fs $syslog $named $network $time
# Required-Stop:     $local_fs $remote_fs $syslog $named $network
# Should-Start:
# Should-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start/Stop the Nagios remote plugin execution daemon
### END INIT INFO


PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
DAEMON=/usr/local/nagios/bin/nrpe
NAME=opsview-agent
DESC=opsview-agent
CONFIG=/usr/local/nagios/etc/nrpe.cfg
PIDFILE=/var/tmp/nrpe.pid

# Problem due to file descriptor left open by Debian apt-get process
exec 3>/dev/null

test -x $DAEMON || exit 0

set -e

. /lib/lsb/init-functions

case "$1" in
  start)
	echo "Starting $DESC" "$NAME"
    # cleanup pidfile if necessary
    if [ -f $PIDFILE ]; then
        ps -p `cat $PIDFILE` | grep nrpe 1>/dev/null || rm -f $PIDFILE
    fi
	start-stop-daemon --chuid nagios --start $NICENESS --exec $DAEMON -- -c $CONFIG -d $DAEMON_OPTS
	;;
  stop)
	echo "Stopping $DESC" "$NAME"
	start-stop-daemon --stop --quiet --oknodo --exec $DAEMON
	;;
  reload|force-reload)
	echo "Reloading $DESC configuration files" "$NAME"
	start-stop-daemon --stop --signal HUP --quiet --exec $DAEMON
	;;
  restart)
	$0 stop
	sleep 1
	$0 start
	;;
  status)
    status=0
    status_of_proc $DAEMON nrpe || status=$?
    exit $status
    ;;
  *)
	echo "Usage: $N {start|stop|restart|reload|force-reload}" >&2
	exit 1
	;;
esac

exit 0
