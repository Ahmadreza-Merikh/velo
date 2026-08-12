# Velo

Velo collects proxy nodes from subscription feeds, tests every one of them with
a real connection, throws away the ones that do not hold up, and connects to
the fastest survivor. There is one big button in the middle of the screen and
you do not have to pick a server yourself.

Two things live in this repository:

* `app/` is the Velo client for Android, macOS and Windows, written in Flutter.
* the Python tool at the repository root is the headless tester the app grew
  out of. It still works and is handy for batch runs on a desktop.

## Downloads

Builds are produced by GitHub Actions and attached to each tagged release:

| Platform | File |
|---|---|
| Android | `app-arm64-v8a-release.apk`, `app-release.apk` (universal) |
| macOS | `velo-macos.dmg` |
| Windows | `velo-windows.zip` |

## How connecting works

The first time you press connect, Velo reads every source it knows about,
parses the share links, and tests them. Testing runs in cycles. Cycle one tests
every node; each later cycle re-tests only the nodes that survived the cycle
before it. A node that answers 20 cycles in a row is a node that actually
works, not one that happened to answer once. What comes out of that is the
pool, sorted by ping.

After that, connecting is quick. Every time you press connect again, Velo runs
a single cycle over the pool it already has, drops whatever stopped answering,
and connects to the fastest node that is left. Disconnect and connect again and
it repeats, so the pool shrinks as nodes die off. When nothing is left in the
pool, Velo starts over from the sources with a full test run.

Latency shown for a node is the average of every measurement taken for it, not
the last one.

## Testing while connected

A test that runs while the tunnel is up is not the same test as one that runs
while it is down. Left alone, testing node B through a tunnel that already runs
on node A measures the whole chain from you through A to B and on to the target.
Everything comes out slower, healthy nodes get thrown away because B refuses the
datacenter address it sees, and worse, a node you could never reach yourself
looks fine, wins the scan, and fails the moment it is used.

So before a background round starts, Velo resolves every candidate to an
address and pins a host route for each one through your physical gateway, in one
call to the privileged helper. The round then measures every node over your own
connection, the same as it would with the tunnel down, and the pins come off
when the round ends. Names are resolved outside the tunnel too, by talking
directly to a public resolver over a pinned route, and the resolved address is
handed to the proxy core so it cannot quietly reach a different one. A node
whose name will not resolve is left in the pool untested rather than counted as
dead.

Measurements carry the state they were taken in, and the two are never averaged
together or compared: a number from an idle machine and a number from a machine
with a tunnel up are different measurements of different things.

Tests that run while connected also run at a lower parallelism than tests on an
idle machine, so a background round does not slow down the traffic you are
actually using.

On Android none of the routing work is needed. The app already excludes itself
from its own tunnel, so its tests go out directly whether or not the tunnel is
up. The lower parallelism still applies.

In proxy mode there is nothing to isolate, and the tester never reads the system
proxy settings, so it is unaffected either way.

## Defaults

| Setting | Default |
|---|---|
| Test cycles | 20 |
| Timeout per node | 10 seconds |
| Cycles before reconnect | 1 |
| Parallel tests | 32 on desktop, 12 on Android |
| Parallel tests while connected | 8 on desktop, 4 on Android |
| Node limit per scan | no limit |

All of them can be changed under the tune icon in the top right. The same
screen has the connection mode, the local port numbers, and the test URL.

## Subscriptions

Velo ships with a set of public sources and searches them on every scan. They
are not listed in the app and there is nothing to paste to get started.

Your own subscriptions go under the link icon in the top left. Both
subscription URLs and raw `vmess://`, `vless://`, `trojan://` and `ss://`
links are accepted. Yours are searched together with the bundled ones, and you
can turn the bundled ones off in the settings if you only want your own.

Supported protocols are vmess, vless including Reality, trojan and
shadowsocks. Links using other protocols are skipped rather than failed.

## Platform notes

### Android

Full tunnel through `VpnService`. Android asks for VPN permission the first
time you connect. Nothing else is needed and no root is involved. The proxy
core runs inside the app process and the app excludes itself from its own
tunnel, so there is no routing loop.

### macOS

The tunnel needs a `utun` interface, which is root only. On the first tunnel
connect Velo asks for your admin password once and installs a small helper at
`/usr/local/libexec/velo`, plus a `sudoers` rule that lets that one helper run
without a password. Connects after that are silent. You can remove both from
the bottom of the settings screen.

The helper is what does the network plumbing. On connect it pins a host route
to the node you are connecting to through your normal gateway, so the proxy
uplink stays off the tunnel, brings the core up, waits for the interface, and
then routes `0.0.0.0/1` and `128.0.0.0/1` through it. Both halves cover the
whole address space without replacing your default route. Every route it adds
is recorded and removed again on disconnect, and a stale set is cleaned up
before a new tunnel starts.

The same helper pins and unpins the routes a background test round needs. Those
are kept in their own list, so unpinning them can never take out the route the
live tunnel is running on, and they are dropped when the tunnel goes down or the
app next starts.

Velo checks the installed helper against the version it expects, so an update
that changes what the helper does asks for your password once more. There is
only ever one helper and one `sudoers` rule.

The app is not signed with an Apple developer certificate, so Gatekeeper will
complain the first time. Clear the quarantine flag after unpacking:

```bash
xattr -cr /Applications/Velo.app
```

### Windows

The tunnel uses Wintun, which needs Administrator to create the adapter. The
first tunnel connect shows one UAC prompt and registers three scheduled tasks:
one brings the tunnel up, one takes it down, and one adds and removes the routes
a background test round needs. Later connects run those tasks and show no
prompt. `wintun.dll` ships next to the executable.

The bring-up task does the same job as the macOS helper: host route to the node
through the current gateway, start the core, wait for the `Velo` adapter, give
it an address, then route both halves of the address space through it. Routes
go into the active store only, so a reboot clears anything left behind.

The route task reads what to pin from a file Velo writes in its own data
directory and answers in a file beside it. Test pins are tracked separately from
the tunnel's own routes and are removed when the round ends or the tunnel stops.
Updating Velo shows the UAC prompt once more if the tasks it needs have changed.

### Proxy fallback

If the tunnel cannot start, and it is left enabled, Velo runs the core as a
local proxy instead and points the system proxy settings at it, then shows a
`Proxy mode` badge so you can tell the difference. Coverage is smaller than a
tunnel because only apps that honour the system proxy are affected. Turn the
fallback off in the settings if you would rather see the connection fail.

## Building

The platform folders under `app/` are generated rather than committed. After
cloning, with Flutter on your PATH:

```bash
cd app
bash tool/scaffold.sh android,macos,windows
```

That runs `flutter create` for the platforms you asked for, copies the Kotlin
sources, the manifest and the macOS entitlements over the generated tree, and
patches the Gradle files. Then build as usual:

```bash
flutter build apk --release
flutter build macos --release
flutter build windows --release
```

Android needs `libv2ray.aar` in `app/android/app/libs/`. Grab it from the
[AndroidLibXrayLite](https://github.com/2dust/AndroidLibXrayLite) releases.
Desktop builds look for an `xray` binary next to the executable or in
`Contents/Resources`, and download one into the app support directory if there
is none. The release workflows do all of this, so pushing a `v*` tag is the
easiest way to get all three builds.

## Python tool

```bash
./run.sh
```

The script creates a virtualenv, installs the requirements and opens the
desktop tester. For batch runs:

```bash
python3 main.py --cli --cycles 20 --timeout 10
python3 main.py --cli --url https://example.com/sub --no-builtin
```

Results land in `output/`: the working share links, a report, and a base64
subscription you can paste into another client.

## A note on privileges

The macOS helper and the Windows scheduled task both run the proxy core as
root or SYSTEM with a config file that lives in your user directory, and both
will add a host route to any address they are handed. Anyone who can already
write files as your user can therefore influence what the core does with those
privileges and which addresses bypass the tunnel. That is the price of a tunnel
without an Apple developer certificate or a signed Windows service. If that
trade is not one you want, leave the full tunnel off and use proxy mode.

Accepting invalid certificates for sources is off by default. Turning it on
lets a few feeds load that would otherwise fail, and also means those feeds
can be tampered with in transit.

## Credits

Proxy core is [Xray-core](https://github.com/XTLS/Xray-core). Android bindings
come from [AndroidLibXrayLite](https://github.com/2dust/AndroidLibXrayLite).
The Windows tunnel uses [Wintun](https://www.wintun.net/).

## License

MIT, see [LICENSE](LICENSE).
