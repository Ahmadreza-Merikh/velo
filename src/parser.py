from __future__ import annotations

import base64
import json
import logging
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Tuple
from urllib.parse import parse_qs, unquote, urlparse

logger = logging.getLogger(__name__)


@dataclass
class ParsedConfig:
    raw: str
    protocol: str
    name: str
    outbound: Dict[str, Any]
    server: str = ""
    port: int = 0
    ok: bool = True
    error: str = ""


def _b64_decode(data: str) -> bytes:
    cleaned = "".join(data.split())
    pad = (-len(cleaned)) % 4
    cleaned += "=" * pad
    try:
        return base64.urlsafe_b64decode(cleaned)
    except Exception:
        return base64.b64decode(cleaned)


def _qs_first(qs: Dict[str, List[str]], key: str, default: str = "") -> str:
    vals = qs.get(key) or qs.get(key.lower()) or []
    return vals[0] if vals else default


def _fragment_name(uri: str, fallback: str = "unnamed") -> str:
    if "#" in uri:
        return unquote(uri.split("#", 1)[1]) or fallback
    return fallback


def _stream_settings_from_params(
    qs: Dict[str, List[str]],
    security_default: str = "none",
) -> Dict[str, Any]:
    network = (_qs_first(qs, "type") or _qs_first(qs, "net") or "tcp").lower()
    security = (
        _qs_first(qs, "security")
        or _qs_first(qs, "tls")
        or security_default
    ).lower()
    if security in ("1", "true", "tls"):
        security = "tls"
    if security in ("0", "false", ""):
        security = "none"

    stream: Dict[str, Any] = {
        "network": network if network else "tcp",
        "security": security if security else "none",
    }

    if network in ("ws", "websocket"):
        stream["network"] = "ws"
        ws: Dict[str, Any] = {
            "path": unquote(_qs_first(qs, "path", "/")),
        }
        host = _qs_first(qs, "host") or _qs_first(qs, "Host")
        if host:
            ws["headers"] = {"Host": host}
        stream["wsSettings"] = ws

    elif network in ("grpc", "gun"):
        stream["network"] = "grpc"
        stream["grpcSettings"] = {
            "serviceName": unquote(
                _qs_first(qs, "serviceName") or _qs_first(qs, "path") or ""
            ),
            "multiMode": _qs_first(qs, "mode", "").lower() == "multi",
        }

    elif network in ("h2", "http"):
        stream["network"] = "h2"
        host = _qs_first(qs, "host")
        path = unquote(_qs_first(qs, "path", "/"))
        stream["httpSettings"] = {
            "path": path,
            "host": [h.strip() for h in host.split(",") if h.strip()] if host else [],
        }

    elif network in ("httpupgrade", "http_upgrade"):
        stream["network"] = "httpupgrade"
        path = unquote(_qs_first(qs, "path", "/"))
        host = _qs_first(qs, "host")
        hu: Dict[str, Any] = {"path": path}
        if host:
            hu["host"] = host
        stream["httpupgradeSettings"] = hu

    elif network in ("splithttp", "xhttp"):
        stream["network"] = "xhttp"
        path = unquote(_qs_first(qs, "path", "/"))
        host = _qs_first(qs, "host")
        xh: Dict[str, Any] = {"path": path}
        if host:
            xh["host"] = host
        mode = _qs_first(qs, "mode")
        if mode:
            xh["mode"] = mode
        stream["xhttpSettings"] = xh

    elif network == "kcp" or network == "mkcp":
        stream["network"] = "kcp"
        stream["kcpSettings"] = {
            "mtu": 1350,
            "tti": 50,
            "uplinkCapacity": 12,
            "downlinkCapacity": 100,
            "congestion": False,
            "header": {
                "type": _qs_first(qs, "headerType") or _qs_first(qs, "type", "none")
            },
            "seed": _qs_first(qs, "seed") or _qs_first(qs, "path") or None,
        }
        if stream["kcpSettings"]["seed"] is None:
            del stream["kcpSettings"]["seed"]

    else:
        stream["network"] = "tcp"
        header_type = _qs_first(qs, "headerType") or _qs_first(qs, "header", "none")
        if header_type and header_type != "none":
            tcp: Dict[str, Any] = {
                "header": {"type": header_type},
            }
            if header_type == "http":
                host = _qs_first(qs, "host")
                path = unquote(_qs_first(qs, "path", "/"))
                tcp["header"]["request"] = {
                    "path": [path],
                    "headers": {"Host": [host] if host else []},
                }
            stream["tcpSettings"] = tcp

    if security == "tls":
        tls: Dict[str, Any] = {
            "allowInsecure": _qs_first(qs, "allowInsecure", "0")
            in ("1", "true", "True"),
            "serverName": _qs_first(qs, "sni")
            or _qs_first(qs, "peer")
            or _qs_first(qs, "host")
            or "",
        }
        fp = _qs_first(qs, "fp") or _qs_first(qs, "fingerprint")
        if fp:
            tls["fingerprint"] = fp
        alpn = _qs_first(qs, "alpn")
        if alpn:
            tls["alpn"] = [a.strip() for a in unquote(alpn).split(",") if a.strip()]
        stream["tlsSettings"] = tls

    elif security == "reality":
        pbk = _qs_first(qs, "pbk") or _qs_first(qs, "publicKey")
        sid = _qs_first(qs, "sid") or _qs_first(qs, "shortId")
        spx = unquote(_qs_first(qs, "spx") or _qs_first(qs, "spiderX") or "")
        sni = (
            _qs_first(qs, "sni")
            or _qs_first(qs, "serverName")
            or _qs_first(qs, "host")
            or ""
        )
        fp = _qs_first(qs, "fp") or _qs_first(qs, "fingerprint") or "chrome"
        stream["realitySettings"] = {
            "show": False,
            "fingerprint": fp,
            "serverName": sni,
            "publicKey": pbk,
            "shortId": sid,
            "spiderX": spx or "/",
        }

    return stream


def parse_vmess(uri: str) -> ParsedConfig:
    name = _fragment_name(uri, "vmess")
    try:
        payload = uri[len("vmess://"):]
        if "#" in payload:
            payload = payload.split("#", 1)[0]
        raw = _b64_decode(payload).decode("utf-8", errors="ignore")
        data = json.loads(raw)
    except Exception as exc:
        return ParsedConfig(
            raw=uri,
            protocol="vmess",
            name=name,
            outbound={},
            ok=False,
            error=str(exc),
        )

    name = data.get("ps") or name
    host = data.get("add") or data.get("host") or ""
    port = int(data.get("port") or 0)
    uuid = data.get("id") or ""
    aid = int(data.get("aid") or data.get("alterId") or 0)
    scy = data.get("scy") or data.get("security") or "auto"
    net = (data.get("net") or "tcp").lower()
    tls_flag = (data.get("tls") or "").lower()
    sni = data.get("sni") or data.get("host") or ""
    path = data.get("path") or "/"
    host_header = data.get("host") or ""
    alpn = data.get("alpn") or ""
    fp = data.get("fp") or data.get("fingerprint") or ""
    header_type = data.get("type") or "none"

    qs: Dict[str, List[str]] = {
        "type": [net],
        "security": ["tls" if tls_flag in ("tls", "1", "true") else "none"],
        "sni": [sni],
        "path": [path],
        "host": [host_header],
        "headerType": [header_type],
        "alpn": [alpn],
        "fp": [fp],
        "serviceName": [path if net == "grpc" else ""],
    }
    stream = _stream_settings_from_params(qs)

    outbound = {
        "protocol": "vmess",
        "settings": {
            "vnext": [
                {
                    "address": host,
                    "port": port,
                    "users": [
                        {
                            "id": uuid,
                            "alterId": aid,
                            "security": scy,
                            "level": 0,
                        }
                    ],
                }
            ]
        },
        "streamSettings": stream,
        "tag": "proxy",
    }
    return ParsedConfig(
        raw=uri,
        protocol="vmess",
        name=str(name),
        outbound=outbound,
        server=host,
        port=port,
    )


def parse_vless(uri: str) -> ParsedConfig:
    name = _fragment_name(uri, "vless")
    try:
        main = uri.split("#", 1)[0]
        parsed = urlparse(main)
        uuid = unquote(parsed.username or "")
        host = parsed.hostname or ""
        port = int(parsed.port or 443)
        qs = parse_qs(parsed.query, keep_blank_values=True)
    except Exception as exc:
        return ParsedConfig(
            raw=uri,
            protocol="vless",
            name=name,
            outbound={},
            ok=False,
            error=str(exc),
        )

    encryption = _qs_first(qs, "encryption", "none") or "none"
    flow = _qs_first(qs, "flow", "")
    stream = _stream_settings_from_params(qs, security_default="none")

    user: Dict[str, Any] = {
        "id": uuid,
        "encryption": encryption,
        "level": 0,
    }
    if flow:
        user["flow"] = flow

    outbound = {
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": host,
                    "port": port,
                    "users": [user],
                }
            ]
        },
        "streamSettings": stream,
        "tag": "proxy",
    }
    return ParsedConfig(
        raw=uri,
        protocol="vless",
        name=name,
        outbound=outbound,
        server=host,
        port=port,
    )


def parse_trojan(uri: str) -> ParsedConfig:
    name = _fragment_name(uri, "trojan")
    try:
        main = uri.split("#", 1)[0]
        parsed = urlparse(main)
        password = unquote(parsed.username or "")
        host = parsed.hostname or ""
        port = int(parsed.port or 443)
        qs = parse_qs(parsed.query, keep_blank_values=True)
    except Exception as exc:
        return ParsedConfig(
            raw=uri,
            protocol="trojan",
            name=name,
            outbound={},
            ok=False,
            error=str(exc),
        )

    if not _qs_first(qs, "security"):
        qs = dict(qs)
        qs["security"] = ["tls"]
    stream = _stream_settings_from_params(qs, security_default="tls")

    outbound = {
        "protocol": "trojan",
        "settings": {
            "servers": [
                {
                    "address": host,
                    "port": port,
                    "password": password,
                    "level": 0,
                }
            ]
        },
        "streamSettings": stream,
        "tag": "proxy",
    }
    return ParsedConfig(
        raw=uri,
        protocol="trojan",
        name=name,
        outbound=outbound,
        server=host,
        port=port,
    )


def parse_shadowsocks(uri: str) -> ParsedConfig:
    name = _fragment_name(uri, "ss")
    try:
        body = uri[len("ss://"):]
        if "#" in body:
            body = body.split("#", 1)[0]

        method = password = host = ""
        port = 0
        plugin = ""

        if "@" in body:
            userinfo, hostinfo = body.rsplit("@", 1)
            head = userinfo.split(":")[0]
            if ":" not in userinfo or not re.match(r"^[a-z0-9\-]+$", head, re.I):
                try:
                    decoded = _b64_decode(userinfo).decode("utf-8", errors="ignore")
                    if ":" in decoded:
                        method, password = decoded.split(":", 1)
                    else:
                        method, password = decoded, ""
                except Exception:
                    method, password = (userinfo.split(":", 1) + [""])[:2]
            else:
                method, password = userinfo.split(":", 1)

            hostport, _, query = hostinfo.partition("?")
            if hostport.startswith("["):
                m = re.match(r"\[([^\]]+)\]:(\d+)", hostport)
                if m:
                    host, port = m.group(1), int(m.group(2))
                else:
                    host, port = hostport, 0
            else:
                hp = hostport.rsplit(":", 1)
                host = hp[0]
                port = int(hp[1]) if len(hp) == 2 else 0

            if query:
                qs = parse_qs(query)
                plugin_raw = _qs_first(qs, "plugin")
                if plugin_raw:
                    plugin = unquote(plugin_raw).split(";")[0]
        else:
            decoded = _b64_decode(body).decode("utf-8", errors="ignore")
            userinfo, hostinfo = decoded.rsplit("@", 1)
            method, password = userinfo.split(":", 1)
            hp = hostinfo.rsplit(":", 1)
            host = hp[0]
            port = int(hp[1]) if len(hp) == 2 else 0

        method = unquote(method)
        password = unquote(password)
        host = host.strip()

        outbound: Dict[str, Any] = {
            "protocol": "shadowsocks",
            "settings": {
                "servers": [
                    {
                        "address": host,
                        "port": int(port),
                        "method": method,
                        "password": password,
                        "level": 0,
                    }
                ]
            },
            "tag": "proxy",
        }

        if plugin:
            logger.debug("shadowsocks plugin %s may require extra setup", plugin)

        return ParsedConfig(
            raw=uri,
            protocol="ss",
            name=name,
            outbound=outbound,
            server=host,
            port=int(port),
        )
    except Exception as exc:
        return ParsedConfig(
            raw=uri,
            protocol="ss",
            name=name,
            outbound={},
            ok=False,
            error=str(exc),
        )


def parse_config(uri: str) -> ParsedConfig:
    uri = uri.strip()
    lower = uri.lower()

    if lower.startswith("vmess://"):
        return parse_vmess(uri)
    if lower.startswith("vless://"):
        return parse_vless(uri)
    if lower.startswith("trojan://"):
        return parse_trojan(uri)
    if lower.startswith("ss://"):
        return parse_shadowsocks(uri)

    scheme = lower.split("://", 1)[0] if "://" in lower else "unknown"
    return ParsedConfig(
        raw=uri,
        protocol=scheme,
        name=_fragment_name(uri, scheme),
        outbound={},
        ok=False,
        error="unsupported protocol: " + scheme,
    )


def build_test_config(outbound: Dict[str, Any], local_port: int) -> Dict[str, Any]:
    return {
        "log": {"loglevel": "error"},
        "inbounds": [
            {
                "tag": "socks-in",
                "port": local_port,
                "listen": "127.0.0.1",
                "protocol": "socks",
                "settings": {
                    "auth": "noauth",
                    "udp": True,
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"],
                },
            }
        ],
        "outbounds": [
            outbound,
            {
                "protocol": "freedom",
                "tag": "direct",
            },
            {
                "protocol": "blackhole",
                "tag": "block",
            },
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {
                    "type": "field",
                    "outboundTag": "proxy",
                    "network": "tcp,udp",
                }
            ],
        },
    }


def parse_many(uris: List[str]) -> Tuple[List[ParsedConfig], List[ParsedConfig]]:
    ok: List[ParsedConfig] = []
    failed: List[ParsedConfig] = []
    for uri in uris:
        p = parse_config(uri)
        if p.ok and p.outbound:
            ok.append(p)
        else:
            failed.append(p)
    return ok, failed
