"""Execute PostgreSQL inside the delivered image using its own postgres account."""
import os
import pwd
import sys

os.chroot(sys.argv[1])
os.chdir('/tmp')
account = pwd.getpwnam('postgres')
os.setgroups([])
os.setgid(account.pw_gid)
os.setuid(account.pw_uid)
os.environ.pop('LD_LIBRARY_PATH', None)
os.environ['HOME'] = '/tmp'
os.execvpe(sys.argv[2], sys.argv[2:], os.environ)
