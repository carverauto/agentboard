"""Run an image entrypoint in its exported rootfs with the image's numeric user."""
import os
import sys

os.chroot(sys.argv[1])
os.chdir('/app')
os.setgroups([])
os.setgid(10001)
os.setuid(10001)
os.environ['HOME'] = '/tmp'
os.execvpe(sys.argv[2], sys.argv[2:], os.environ)
