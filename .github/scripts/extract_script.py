import io
import re
import sys

source = io.open(sys.argv[1], encoding='utf-8').read()
name = sys.argv[2]
match = re.search(
    r"static const String %s = r'''(.*?)''';" % re.escape(name),
    source,
    re.S,
)
if match is None:
    sys.stderr.write('could not find %s\n' % name)
    sys.exit(1)
sys.stdout.write(match.group(1))
