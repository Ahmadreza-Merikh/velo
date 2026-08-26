import io
import re
import sys

source = io.open(sys.argv[1], encoding='utf-8').read()
name = sys.argv[2]

DECL = r"static const String %s =\s*(.*?);\n"
PART = re.compile(r"r'''(.*?)'''|([A-Za-z_][A-Za-z0-9_]*)", re.S)


def resolve(target, seen):
    if target in seen:
        sys.stderr.write('%s is defined in terms of itself\n' % target)
        sys.exit(1)
    seen = seen | {target}
    match = re.search(DECL % re.escape(target), source, re.S)
    if match is None:
        sys.stderr.write('could not find %s\n' % target)
        sys.exit(1)
    out = []
    for literal, reference in PART.findall(match.group(1)):
        if reference:
            out.append(resolve(reference, seen))
        else:
            out.append(literal)
    return ''.join(out)


sys.stdout.write(resolve(name, frozenset()))
