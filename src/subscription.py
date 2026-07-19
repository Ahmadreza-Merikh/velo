from __future__ import annotations

import base64
import logging
import re
from typing import List, Sequence, Tuple
from urllib.parse import unquote

import requests

logger = logging.getLogger(__name__)

SUPPORTED_SCHEMES = (
    "vmess://",
    "vless://",
    "trojan://",
    "ss://",
    "ssr://",
    "hysteria2://",
    "hy2://",
    "tuic://",
    "wireguard://",
)

DEFAULT_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    ),
    "Accept": "*/*",
}

_SCHEME_RE = re.compile(
    r"(?i)((?:vmess|vless|trojan|ss|ssr|hysteria2|hy2|tuic|wireguard)://\S+)"
)


def _try_b64_decode(data: str) -> str | None:
    cleaned = "".join(data.split())
    if not cleaned:
        return None

    for decoder in (base64.b64decode, base64.urlsafe_b64decode):
        for pad in ("", "=", "==", "==="):
            try:
                raw = decoder(cleaned + pad, validate=False)
                text = raw.decode("utf-8", errors="ignore")
                if text.strip():
                    return text
            except Exception:
                continue
    return None


def decode_subscription_body(body: str) -> str:
    body = body.strip()
    if not body:
        return ""

    lower = body.lower()
    if any(scheme in lower for scheme in SUPPORTED_SCHEMES):
        return body

    decoded = _try_b64_decode(body)
    return decoded if decoded is not None else body


def _split_share_links(line: str) -> List[str]:
    matches = _SCHEME_RE.findall(line)
    if matches:
        return [m.rstrip(",;") for m in matches]

    lower = line.lower()
    for scheme in SUPPORTED_SCHEMES:
        if lower.startswith(scheme):
            return [line]
    return []


def extract_configs(text: str) -> List[str]:
    configs: List[str] = []
    seen: set[str] = set()

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue

        if "%" in line and "://" not in line[:12]:
            try:
                line = unquote(line).strip()
            except Exception:
                pass

        for link in _split_share_links(line):
            link = link.strip().rstrip("\r")
            if not link or link in seen:
                continue
            seen.add(link)
            configs.append(link)

    return configs


def fetch_subscription(
    url: str,
    timeout: float = 30.0,
    session: requests.Session | None = None,
) -> Tuple[List[str], str | None]:
    url = url.strip()
    if not url:
        return [], "empty url"

    sess = session or requests.Session()
    try:
        resp = sess.get(url, headers=DEFAULT_HEADERS, timeout=timeout)
        resp.raise_for_status()
        try:
            body = resp.content.decode("utf-8", errors="ignore")
        except Exception:
            body = resp.text

        configs = extract_configs(decode_subscription_body(body))
        if not configs:
            return [], "no proxy links found"
        return configs, None
    except requests.Timeout:
        return [], "timeout"
    except requests.RequestException as exc:
        return [], "fetch failed: " + str(exc)
    except Exception as exc:
        return [], str(exc)


def fetch_all_subscriptions(
    urls: Sequence[str],
    timeout: float = 30.0,
    progress_cb=None,
) -> Tuple[List[str], List[str]]:
    all_configs: List[str] = []
    seen: set[str] = set()
    errors: List[str] = []

    raw_links: List[str] = []
    real_urls: List[str] = []
    for item in urls:
        item = item.strip()
        if not item:
            continue
        lower = item.lower()
        if any(lower.startswith(s) for s in SUPPORTED_SCHEMES):
            raw_links.append(item)
        else:
            real_urls.append(item)

    for link in raw_links:
        if link not in seen:
            seen.add(link)
            all_configs.append(link)

    session = requests.Session()
    total = len(real_urls)
    for idx, url in enumerate(real_urls, start=1):
        if progress_cb:
            progress_cb(idx, total, url)
        configs, err = fetch_subscription(url, timeout=timeout, session=session)
        if err:
            errors.append(url + ": " + err)
            logger.warning("subscription error for %s: %s", url, err)
            continue
        for cfg in configs:
            if cfg not in seen:
                seen.add(cfg)
                all_configs.append(cfg)

    return all_configs, errors


def parse_url_list(text: str) -> List[str]:
    if not text or not text.strip():
        return []

    parts: List[str] = []
    for chunk in re.split(r"[\n,;]+", text):
        chunk = chunk.strip()
        if chunk:
            parts.append(chunk)
    return parts
