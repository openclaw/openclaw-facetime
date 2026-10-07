on run argv
	if (count of argv) is not 1 then error "Expected the packaged privileged installer path"
	set sourceInstaller to item 1 of argv
	set expectedInstallerDigest to "b7ac7899e8622524ded3d3e4378197469463a30806ad350f832c709cf88e80a7"
	set installCommand to "set -eu; " & ¬
		"work=$(/usr/bin/mktemp -d /private/tmp/openclaw-driver-install.XXXXXX); " & ¬
		"cleanup() { if test -x /usr/bin/trash; then /usr/bin/trash \"$work\"; else /usr/bin/python3 -c 'import os, shutil, sys; p=sys.argv[1]; shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else (os.unlink(p) if os.path.lexists(p) else None)' \"$work\"; fi; }; " & ¬
		"trap cleanup EXIT; /bin/chmod 700 \"$work\"; " & ¬
		"/usr/bin/ditto " & quoted form of sourceInstaller & " \"$work/install-driver-root.sh\"; " & ¬
		"actual=$(/usr/bin/shasum -a 256 \"$work/install-driver-root.sh\" | /usr/bin/awk '{print $1}'); " & ¬
		"test \"$actual\" = " & quoted form of expectedInstallerDigest & "; " & ¬
		"/bin/chmod 500 \"$work/install-driver-root.sh\"; " & ¬
		"\"$work/install-driver-root.sh\""
	do shell script installCommand with administrator privileges
end run
