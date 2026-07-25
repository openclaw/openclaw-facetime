on run argv
	if (count of argv) is not 2 then error "Expected source and destination driver paths"
	set sourceDriver to item 1 of argv
	set installedDriver to item 2 of argv
	set installCommand to "set -eu; " & ¬
		"if test -e " & quoted form of installedDriver & "; then " & ¬
		"if test -x /usr/bin/trash; then /usr/bin/trash " & quoted form of installedDriver & "; " & ¬
		"else /usr/bin/python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' " & quoted form of installedDriver & "; fi; fi; " & ¬
		"/usr/bin/ditto " & quoted form of sourceDriver & " " & quoted form of installedDriver & "; " & ¬
		"/usr/sbin/chown -R root:wheel " & quoted form of installedDriver & "; " & ¬
		"/bin/chmod -R go-w " & quoted form of installedDriver & "; " & ¬
		"for pid in $(/usr/bin/pgrep -x coreaudiod || true); do /bin/kill -9 $pid; done"
	do shell script installCommand with administrator privileges
end run
