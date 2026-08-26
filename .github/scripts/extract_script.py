import io
import re
import sys

source = io.open(sys.argv[1], encoding='utf-8').read()
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def fail(why):
    sys.stderr.write(why + '\n')
    sys.exit(1)


def resolve(target, seen):
    if target in seen:
        fail('%s is defined in terms of itself' % target)
    seen = seen | {target}
    head = 'static const String %s =' % target
    at = source.find(head)
    if at < 0:
        fail('could not find %s' % target)
    at += len(head)
    parts = []
    while True:
        while at < len(source) and source[at] in ' \t\n+':
            at += 1
        if at >= len(source):
            fail('%s never ends' % target)
        if source[at] == ';':
            return ''.join(parts)
        if source.startswith("r'''", at):
            shut = source.find("'''", at + 4)
            if shut < 0:
                fail('%s has an unterminated string' % target)
            parts.append(source[at + 4:shut])
            at = shut + 3
            continue
        word = NAME.match(source, at)
        if not word:
            fail('%s has something unexpected in it' % target)
        parts.append(resolve(word.group(0), seen))
        at = word.end()


sys.stdout.write(resolve(sys.argv[2], frozenset()))
