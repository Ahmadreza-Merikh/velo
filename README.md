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

## IPv6

A tunnel that only claims IPv4 is not a tunnel. If your connection has IPv6 and
nothing routes it, every IPv6-reachable destination is contacted directly, with
your real address, outside the tunnel entirely. On Windows that is not an edge
case: Windows prefers IPv6 over IPv4 whenever both are available, so most of the
traffic to large sites would take the direct path.

So on macOS and Windows, Velo turns IPv6 off for as long as the tunnel is up.
The previous setting of every network service is written to disk before anything
is changed, and put back when the tunnel stops. If Velo is killed rather than
closed, the next start reads that file and restores what it found, so you are
never left without IPv6 and without an explanation. A service with a manually
configured IPv6 address is left alone rather than having its configuration
thrown away.

Once the tunnel is up Velo checks the result by trying to reach an IPv6 address
on the internet. If that succeeds, something escaped and Velo says so on the
main screen. The check is a real connection attempt rather than a reading of
system settings, because a setting that claims IPv6 is off is not evidence that
no packet can leave.

Android needs none of this. Its tunnel already claims `::/0` and hands IPv6
packets to the proxy core like any other traffic, so IPv6 is carried rather than
leaked. If the system ever refuses that claim on a device that has IPv6, Velo
refuses to bring the tunnel up rather than run without it.

The `queryStrategy` setting in the generated core config is not part of this. It
only constrains how the core resolves names of its own accord, and has no effect
on the routing table or on traffic addressed to a literal IPv6 address.

## When another VPN is running

Velo pins its own routes to your physical gateway, which it finds by reading the
routing table for a default route that belongs to real hardware. Another VPN
holding the default route no longer hides that gateway, so Velo can start
alongside one. If no physical gateway can be found at all, the error says so and
names the interface that took the default, rather than claiming you are offline.

## Name resolution

Names are looked up over an encrypted connection to a resolver on port 443,
with the certificate checked against the resolver's own hostname. The address
Velo connects to is pinned, but the identity it checks is the name, so an
answer cannot be swapped in transit. A forged answer would otherwise point a
healthy node at a dead address and get it thrown away.

Answers are cached on disk for hours rather than minutes, and the cache is
filled in the background while the tunnel is down, so most nodes need no lookup
at all when a background round runs. Plain unencrypted lookups still exist as a
fallback, but anything they return is marked as unchecked and can never on its
own be treated as proof that a node is gone. A name is only treated as dead when
two separate resolvers say so over the encrypted transport, and that tally is
kept across cache expiry so it is not reset every hour.

If no encrypted resolver answers at all, the round does not fail. Velo falls
back to addresses it already has, including expired ones, and says on the main
screen that names could not be checked. Resolvers that fail are rested for a
few hours and tried again rather than dropped, and which ones work is
remembered per network.

The tune screen has a counter view showing where names were resolved and over
what transport, so it is possible to tell whether the encrypted path is
actually carrying the work.

## When the network changes

Every pinned route points at a gateway. Move from Wi-Fi to cellular, or pick up
a new lease, and that gateway is gone, along with the route the running tunnel
depends on. Velo watches for the change while a background round is running.
When one happens it stops the round, drops every test route, finds the gateway
again and re-points the tunnel's own route at it.

Measurements from the interrupted round are thrown away rather than kept. They
were taken against a gateway that no longer exists, and a partial result from a
network that has moved is worse than no result.

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
to the node you are connecting to through your physical gateway, so the proxy
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
that changes what the helper does asks for your password once more. Before that
happens Velo explains what it is about to do and why, because a password prompt
appearing out of nowhere after an update is indistinguishable from something
unpleasant. There is only ever one helper and one `sudoers` rule.

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
