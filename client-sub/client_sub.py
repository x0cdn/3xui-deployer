#!/usr/bin/env python3
"""client-sub – HTTP-посредник между приложениями и подпиской панели 3X-UI.

Панель отдаёт всем один и тот же ответ, а приложениям нужны разные вещи. Этот сервис
стоит перед подпиской панели (обычно на 127.0.0.1, TLS снимает nginx) и правит ответ
под конкретного клиента:

  * ядро Mihomo (Clash Verge, FlClash, Mihomo Party…) – получает Clash-YAML панели
    плюс прокси AmneziaWG из отдельной подписки «<id>-awg», группу автовыбора и DNS;
  * клиенты на sing-box (Karing, Hiddify…), просящие формат Clash, – тот же YAML,
    но без AmneziaWG и без правил маршрутизации: они их не понимают;
  * Hiddify дополнительно представляется панели без слова Clash в User-Agent,
    иначе панель отдаёт ему YAML, который он не может разобрать;
  * JSON-подписке Xray проставляется encryption=none у VLESS-пользователей;
  * из Subscription-Userinfo убирается expire=0 (приложения иначе показывают 1970 год);
  * из списка ссылок удаляются vpn:// и tg:// – их не читает ни один VPN-клиент.

Необязательные файлы рядом с конфигом:
  rules.yaml      – раздельная маршрутизация: через VPN только перечисленное;
  sni-grace.json  – карта «прежнее имя сайта REALITY -> нынешнее» на льготный срок.

Конфиг: $CLIENT_SUB_CONFIG, либо config.json из $CREDENTIALS_DIRECTORY (systemd
LoadCredential), либо /etc/client-sub/config.json. Запуск без конфига невозможен.
"""

import base64
import http.client
import http.server
import ipaddress
import json
import os
import re
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request

import yaml



_CREDS_DIR = os.environ.get("CREDENTIALS_DIRECTORY", "")


def _config_path():
    override = os.environ.get("CLIENT_SUB_CONFIG")
    if override:
        return override
    if _CREDS_DIR:
        candidate = os.path.join(_CREDS_DIR, "config.json")
        if os.path.exists(candidate):
            return candidate
    return "/etc/client-sub/config.json"


with open(_config_path(), encoding="utf-8") as _fh:
    CONF = json.load(_fh)

SUB_PREFIX = "/" + CONF["path"].strip("/") + "/"
UPSTREAM = CONF["upstream"].rstrip("/")

EXTRA_PREFIXES = tuple(
    "/" + p.strip("/") + "/"
    for p in CONF.get("extra_paths", [])
    if isinstance(p, str) and re.fullmatch(r"/?[A-Za-z0-9_-]+/?", p)
)

RULES_PATH = os.environ.get("CLIENT_SUB_RULES") or "/etc/client-sub/rules.yaml"
GRACE_PATH = os.environ.get("CLIENT_SUB_GRACE") or "/etc/client-sub/sni-grace.json"

RULES_BYTE_LIMIT = 64 * 1024
RULES_COUNT_LIMIT = 300
GRACE_BYTE_LIMIT = 64 * 1024
JSON_BODY_LIMIT = 2 * 1024 * 1024

ID_PATTERN = re.compile(r"[A-Za-z0-9_.@-]{1,64}")

ASSET_PATTERN = re.compile(r"assets/[A-Za-z0-9_.-]{1,128}\.(js|css|woff2?|svg|png|ico|map)")

CLASH_CLIENT = re.compile(r"clash|mihomo|flclash|stash|nyanpasu|meta", re.I)


NOT_MIHOMO = re.compile(
    r"karing|hiddify|nekobox|sing-?box|husi|stash|shadowrocket|v2box|streisand|happ|loon|surge|quantumult", re.I)
HIDDIFY_CLIENT = re.compile(r"hiddify", re.I)

RULE_PATTERN = re.compile(
    r"(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|GEOSITE|IP-CIDR|IP-CIDR6|GEOIP),([A-Za-z0-9._:/!@+-]{1,120})")
DOH_PATTERN = re.compile(r"https://[A-Za-z0-9.-]{1,100}(:\d{1,5})?/[A-Za-z0-9._/-]{0,60}")
HOSTNAME_PATTERN = re.compile(r"[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+")
SNI_PARAM = re.compile(r"([?&]sni=)([^&#\s]*)")

DEFAULT_DOH = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
LOCAL_NETS = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16"]



FORWARDED_HEADERS = (
    "content-type", "content-disposition", "profile-title", "profile-update-interval",
    "profile-web-page-url", "subscription-userinfo", "support-url", "cache-control",
    "routing", "routing-enable", "announce", "providerid", "new-url", "fallback-url",
    "hide-settings", "no-limit-enabled", "ping-type", "color-profile", "tun-mode", "tun-type",
    "exclude-routes", "exclude-apns-enable", "per-app-proxy-mode", "per-app-proxy-list",
    "notification-subs-expire", "sub-expire", "sub-expire-button-link", "sub-info-text",
    "sub-info-color", "sub-info-button-text", "sub-info-button-link",
    "subscription-autoconnect", "subscription-autoconnect-type", "subscription-always-hwid-enable",
)


def log(message):
    print(message, flush=True)





def panel_response(sub_id, user_agent, host, accept, prefix=SUB_PREFIX):
    """Ответ подписки панели: (статус, заголовки в нижнем регистре, тело).
    При недоступности панели – (None, {}, b"")."""
    request = urllib.request.Request(
        UPSTREAM + prefix + sub_id,
        headers={"User-Agent": user_agent, "Host": host, "Accept": accept or "*/*"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, {k.lower(): v for k, v in exc.headers.items()}, exc.read()
    except (urllib.error.URLError, http.client.HTTPException, OSError, socket.timeout) as exc:
        log(f"панель недоступна: {exc}")
        return None, {}, b""


def presented_user_agent(user_agent):


    if HIDDIFY_CLIENT.search(user_agent):
        return CLASH_CLIENT.sub("", user_agent).strip()
    return user_agent


def clean_userinfo(header_value):

    kept = [part.strip() for part in header_value.split(";")]
    return "; ".join(part for part in kept if part and part != "expire=0")





def load_grace_map():
    """Необязательная карта переименования сайта REALITY: старое имя -> новое.
    Принимаем только пары валидных доменных имён, не более сотни."""
    try:
        with open(GRACE_PATH, "rb") as fh:
            raw = fh.read(GRACE_BYTE_LIMIT + 1)
        if len(raw) > GRACE_BYTE_LIMIT:
            return {}
        parsed = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError, UnicodeError, RecursionError):
        return {}
    if not isinstance(parsed, dict):
        return {}
    result = {}
    for old, new in list(parsed.items())[:100]:
        if (isinstance(old, str) and isinstance(new, str)
                and len(old) <= 253 and len(new) <= 253
                and HOSTNAME_PATTERN.fullmatch(old) and HOSTNAME_PATTERN.fullmatch(new)):
            result[old] = new
    return result


def _remap_link_sni(link, grace_map):
    if not link.startswith("vless://") or "security=reality" not in link:
        return link
    return SNI_PARAM.sub(lambda m: m.group(1) + grace_map.get(m.group(2), m.group(2)), link)


def rewrite_link_list(body, grace_map):
    """Подписка-список ссылок (base64 или plain text): выкидываем vpn:// (AmneziaVPN)
    и tg:// (прокси Telegram) – ни один клиент подписок их не понимает; меняем льготное
    имя сайта REALITY на актуальное. Формат ответа сохраняем."""
    text = body.decode("utf-8", "replace").strip()
    was_encoded = "://" not in text
    if was_encoded:
        try:
            text = base64.b64decode(text + "=" * (-len(text) % 4)).decode("utf-8", "replace")
        except ValueError:
            return body
    kept = []
    for line in text.splitlines():
        if not line.strip() or line.startswith(("vpn://", "tg://")):
            continue
        kept.append(_remap_link_sni(line, grace_map) if grace_map else line)
    joined = "\n".join(kept)
    return base64.b64encode(joined.encode()).decode().encode() if was_encoded else joined.encode()


def patch_xray_json(body, grace_map):
    """JSON-подписка для Xray: у VLESS-пользователя без encryption (поля нет или оно пустое)
    ставим "none", иначе Xray не примет конфиг. Непустые значения (mlkem и т.п.) не трогаем.
    Пользователи встречаются в двух формах: outbounds[].settings.vnext[].users[] и плоская
    settings.id/encryption. Заодно меняем льготное имя сайта REALITY. Если тело не разобралось,
    слишком большое или правок нет – возвращаем как есть."""
    if len(body) > JSON_BODY_LIMIT:
        return body
    try:
        document = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeError, RecursionError):
        log("JSON-подписка не разобралась – отдаю без правок")
        return body
    touched = False

    def ensure_encryption(user):
        nonlocal touched
        if isinstance(user, dict) and user.get("encryption") in (None, ""):
            user["encryption"] = "none"
            touched = True

    configs = document if isinstance(document, list) else [document]
    for config in configs:
        if not isinstance(config, dict):
            continue
        outbounds = config.get("outbounds")
        for outbound in outbounds if isinstance(outbounds, list) else []:
            if not isinstance(outbound, dict):
                continue
            stream = outbound.get("streamSettings")
            reality = stream.get("realitySettings") if isinstance(stream, dict) else None
            if grace_map and isinstance(reality, dict) and reality.get("serverName") in grace_map:
                reality["serverName"] = grace_map[reality["serverName"]]
                touched = True
            if outbound.get("protocol") != "vless":
                continue
            settings = outbound.get("settings")
            if not isinstance(settings, dict):
                continue
            vnext = settings.get("vnext")
            for server in vnext if isinstance(vnext, list) else []:
                users = server.get("users") if isinstance(server, dict) else None
                for user in users if isinstance(users, list) else []:
                    ensure_encryption(user)
            if "id" in settings:
                ensure_encryption(settings)
    return json.dumps(document, ensure_ascii=False).encode() if touched else body





def _dump_yaml(config):
    return yaml.safe_dump(config, allow_unicode=True, sort_keys=False).encode()


def drop_amnezia(yaml_body):
    """Clash-YAML для клиентов без поддержки AmneziaWG: убираем такие прокси и их имена из групп."""
    config = yaml.safe_load(yaml_body)
    if not isinstance(config, dict):
        return yaml_body
    proxies = config.get("proxies") or []
    banned = {p.get("name") for p in proxies if isinstance(p, dict) and "amnezia-wg-option" in p}
    if not banned:
        return yaml_body
    config["proxies"] = [p for p in proxies if p.get("name") not in banned]
    for group in config.get("proxy-groups") or []:
        members = group.get("proxies")
        if isinstance(members, list):
            group["proxies"] = [name for name in members if name not in banned]
    return _dump_yaml(config)


def attach_amnezia(main_body, awg_body):
    """Подмешивает прокси AmneziaWG из подписки «<id>-awg» в основной Clash-YAML
    и во все группы, где перечислены прокси."""
    main = yaml.safe_load(main_body)
    extra_cfg = yaml.safe_load(awg_body)
    if not isinstance(main, dict) or not isinstance(extra_cfg, dict):
        return main_body
    incoming = [p for p in extra_cfg.get("proxies") or [] if isinstance(p, dict) and p.get("name")]
    if not incoming:
        return main_body
    taken = {p.get("name") for p in main.get("proxies") or []}
    for proxy in incoming:

        proxy["name"] = re.sub(r"-[^-\s]+-awg\d*$", "", proxy["name"]) or proxy["name"]
        base, suffix = proxy["name"], 2
        while proxy["name"] in taken:
            proxy["name"] = f"{base} {suffix}"
            suffix += 1
        taken.add(proxy["name"])
    main.setdefault("proxies", []).extend(incoming)
    new_names = [p["name"] for p in incoming]
    for group in main.get("proxy-groups") or []:
        members = group.get("proxies")
        if isinstance(members, list) and any(name in taken for name in members):

            cut = members.index("DIRECT") if "DIRECT" in members else len(members)
            group["proxies"] = members[:cut] + new_names + members[cut:]
    return _dump_yaml(main)


AUTO_GROUP_NAME = "Авто"


def insert_auto_group(yaml_body):
    """Группа url-test «Авто» первой в списке: клиент сам держится быстрейшего рабочего
    протокола и переключается при отказе. WireGuard/AmneziaWG в автовыбор не берём –
    они разрешают имена на клиенте, а автовыбор должен идти протоколами с DNS на сервере."""
    config = yaml.safe_load(yaml_body)
    if not isinstance(config, dict):
        return yaml_body
    proxies = [p for p in config.get("proxies") or [] if isinstance(p, dict) and p.get("name")]
    all_names = [p["name"] for p in proxies]
    candidates = [p["name"] for p in proxies
                  if p.get("type") != "wireguard" and "amnezia-wg-option" not in p]
    groups = config.get("proxy-groups")
    if (len(candidates) < 2 or not isinstance(groups, list)
            or any(isinstance(g, dict) and g.get("name") == AUTO_GROUP_NAME for g in groups)):
        return yaml_body
    groups.insert(0, {
        "name": AUTO_GROUP_NAME, "type": "url-test",
        "url": "http://www.gstatic.com/generate_204",
        "interval": 300, "tolerance": 100, "lazy": True, "proxies": candidates,
    })
    for group in groups[1:]:
        members = group.get("proxies") if isinstance(group, dict) else None
        if (isinstance(group, dict) and group.get("type") == "select"
                and isinstance(members, list) and any(name in all_names for name in members)):
            group["proxies"] = [AUTO_GROUP_NAME] + members
            break
    return _dump_yaml(config)





SAFE_DNS = {
    "enable": True,
    "ipv6": False,
    "enhanced-mode": "fake-ip",
    "fake-ip-range": "198.18.0.1/16",
    "fake-ip-filter": ["*.lan", "+.local"],
    "respect-rules": True,
    "default-nameserver": ["1.1.1.1", "8.8.8.8"],
    "nameserver": list(DEFAULT_DOH),
    "proxy-server-nameserver": list(DEFAULT_DOH),
}


def ensure_dns(yaml_body):
    config = yaml.safe_load(yaml_body)
    if not isinstance(config, dict) or "dns" in config:
        return yaml_body
    config["dns"] = dict(SAFE_DNS)
    return _dump_yaml(config)





def read_rules(report=None):
    """rules.yaml: список via_vpn («ТИП,ЗНАЧЕНИЕ») и необязательный direct_dns (DoH для
    остального трафика). Возвращает (правила, direct_dns) либо None, если файла нет или
    он непригоден – тогда подписка работает как обычно, всё через VPN.
    Файл читается при каждом запросе: правки применяются без перезапуска."""
    say = report or log
    try:
        with open(RULES_PATH, "rb") as fh:
            raw = fh.read(RULES_BYTE_LIMIT + 1)
    except FileNotFoundError:
        return None
    except OSError as exc:
        say(f"правила: не читается {RULES_PATH}: {exc}")
        return None
    if len(raw) > RULES_BYTE_LIMIT:
        say(f"правила: файл больше {RULES_BYTE_LIMIT // 1024} КБ – пропускаю")
        return None
    try:
        document = yaml.safe_load(raw.decode("utf-8-sig")) or {}
    except (yaml.YAMLError, UnicodeError) as exc:
        say(f"правила: YAML не разобран ({exc}) – пропускаю")
        return None
    entries = document.get("via_vpn") if isinstance(document, dict) else None
    if not isinstance(entries, list) or not entries:
        say("правила: список via_vpn пуст или отсутствует – пропускаю")
        return None

    accepted, seen = [], set()
    for entry in entries[:RULES_COUNT_LIMIT + 50]:
        normalized = re.sub(r"\s*,\s*", ",", str(entry).strip())
        kind, _, value = normalized.partition(",")
        match = RULE_PATTERN.fullmatch(kind.upper() + "," + value)
        if not match:
            say(f"правила: не понимаю {str(entry)[:80]!r} – пропускаю")
            continue
        kind, value = match.group(1), match.group(2)
        if kind in ("IP-CIDR", "IP-CIDR6"):
            try:
                network = ipaddress.ip_network(value, strict=False)
            except ValueError:
                network = None
            if network is None or network.version != (6 if kind == "IP-CIDR6" else 4):
                say(f"правила: подсеть {value!r} неверна – пропускаю")
                continue
        if kind == "DOMAIN-KEYWORD" and len(value) < 4:
            say(f"правила: слово {value!r} короче 4 букв, под него попадёт почти всё – пропускаю")
            continue
        if (kind, value) not in seen and len(accepted) < RULES_COUNT_LIMIT:
            seen.add((kind, value))
            accepted.append((kind, value))
    if not accepted:
        say("правила: пригодных строк не нашлось – пропускаю")
        return None

    dns_list = document.get("direct_dns")
    direct_dns = ([d for d in dns_list if isinstance(d, str) and DOH_PATTERN.fullmatch(d)][:4]
                  if isinstance(dns_list, list) else [])
    return accepted, direct_dns


def apply_split_routing(yaml_body, rules_data):
    """Перечисленное в rules.yaml идёт через VPN (первая группа), остальное – напрямую.
    DNS не утекает: имена из списка в fake-ip вообще не разрешаются на клиенте (сайт
    называется серверу), запросы про них – по DoH через VPN, прочие – системный DNS
    или direct_dns."""
    config = yaml.safe_load(yaml_body)
    if not isinstance(config, dict):
        return yaml_body
    group_names = [g.get("name") for g in config.get("proxy-groups") or []
                   if isinstance(g, dict) and g.get("name")]
    proxy_names = [p.get("name") for p in config.get("proxies") or []
                   if isinstance(p, dict) and p.get("name")]
    vpn_target = group_names[0] if group_names else (proxy_names[0] if proxy_names else None)
    if vpn_target is None:
        return yaml_body

    rules, direct_dns = rules_data
    lines = [f"IP-CIDR,{net},DIRECT,no-resolve" for net in LOCAL_NETS]

    lines += [f"IP-CIDR,{addr}/32,{vpn_target},no-resolve" for addr in ("1.1.1.1", "8.8.8.8")]
    dns_policy = {}
    for kind, value in rules:

        suffix = ",no-resolve" if kind in ("IP-CIDR", "IP-CIDR6", "GEOIP") else ""
        lines.append(f"{kind},{value},{vpn_target}{suffix}")
        if kind == "GEOSITE":
            dns_policy["geosite:" + value] = DEFAULT_DOH
        elif kind == "DOMAIN-SUFFIX":
            dns_policy["+." + value] = DEFAULT_DOH
        elif kind == "DOMAIN":
            dns_policy[value] = DEFAULT_DOH
    lines.append("MATCH,DIRECT")

    config["mode"] = "rule"
    config["rules"] = lines
    dns = dict(SAFE_DNS)
    dns["nameserver"] = direct_dns or ["system"]
    if dns_policy:
        dns["nameserver-policy"] = dns_policy
    config["dns"] = dns

    config["sniffer"] = {
        "enable": True, "override-destination": False,
        "sniff": {"TLS": {"ports": [443, 8443]}, "HTTP": {"ports": [80, "8080-8880"]}, "QUIC": {"ports": [443]}},
    }
    return _dump_yaml(config)


def panel_routing_profile(format_name, rules_data):
    """Профиль маршрутизации для самой панели (она рассылает его Xray-клиентам).
    happ – ссылка happ://routing/onadd/<base64> для заголовка Routing приложения Happ;
    json – профиль для JSON-подписки Xray. Конструктор панели всегда завершает список
    правилом «всё через прокси», поэтому прямой трафик описываем раньше него
    (порядок block-proxy-direct, прямые regexp:.* и 0.0.0.0/0)."""
    rules, direct_dns = rules_data
    sites, ips = [], []
    for kind, value in rules:
        if kind == "GEOSITE":
            sites.append("geosite:" + value)
        elif kind == "DOMAIN-SUFFIX":
            sites.append("domain:" + value)
        elif kind == "DOMAIN":
            sites.append("full:" + value)
        elif kind == "DOMAIN-KEYWORD":
            sites.append(value)
        elif kind == "GEOIP":
            ips.append("geoip:" + value)
        else:
            ips.append(value)
    if format_name == "happ":
        profile = {
            "Name": "3X-UI", "GlobalProxy": "false", "DomainStrategy": "IPIfNonMatch",
            "ProxySites": sites, "ProxyIp": ips, "DirectIp": ["geoip:private"],
        }
    else:

        profile = {
            "Name": "3X-UI", "DomainStrategy": "IPIfNonMatch", "RouteOrder": "block-proxy-direct",
            "ProxySites": sites, "ProxyIp": ["1.1.1.1", "8.8.8.8"] + ips,
            "DirectSites": ["regexp:.*"], "DirectIp": ["geoip:private", "0.0.0.0/0", "::/0"],
            "DomesticDNSDomain": direct_dns[0] if direct_dns else "localhost",
        }
    text = json.dumps(profile, ensure_ascii=False, separators=(",", ":"))
    if format_name == "happ":
        return "happ://routing/onadd/" + base64.b64encode(text.encode()).decode()
    return text


GEO_DATABASE_URL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/{}.dat"


def missing_geo_categories(kind, names):
    """Сверяет имена GEOSITE/GEOIP с базой meta-rules-dat, которую скачают клиенты:
    несуществующая категория не даст конфигу запуститься. GitHub недоступен – не проверяем."""
    if not names:
        return []
    try:
        with urllib.request.urlopen(GEO_DATABASE_URL.format(kind), timeout=30) as response:
            database = response.read(48 * 1024 * 1024)
    except (urllib.error.URLError, OSError) as exc:
        print(f"Категории {kind.upper()} не сверил: база недоступна ({exc}). "
              "Проверьте названия по github.com/MetaCubeX/meta-rules-dat.")
        return []

    return [name for name in names
            if b"\x0a" + bytes([len(name)]) + name.upper().encode() not in database]





class SubscriptionHandler(http.server.BaseHTTPRequestHandler):

    server_version = "nginx"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 20

    def version_string(self):
        return self.server_version

    def setup(self):

        self.request.settimeout(self.timeout)
        if self.server.tls_context is not None:
            self.request = self.server.tls_context.wrap_socket(self.request, server_side=True)
        super().setup()

    def handle(self):
        try:
            super().handle()
        except (ssl.SSLError, ConnectionError, socket.timeout, OSError):
            pass

    def log_message(self, fmt, *args):
        pass

    def _connection_header(self):
        self.send_header("Connection", "close" if self.close_connection else "keep-alive")

    def _reply(self, code, content_type, body):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self._connection_header()
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def nginx_error(self, code):
        phrase = self.responses.get(code, ("Error",))[0]
        page = (f"<html>\r\n<head><title>{code} {phrase}</title></head>\r\n<body>\r\n"
                f"<center><h1>{code} {phrase}</h1></center>\r\n"
                "<hr><center>nginx</center>\r\n</body>\r\n</html>\r\n").encode()
        self._reply(code, "text/html", page)

    def send_error(self, code, message=None, explain=None):


        self.request_version = "HTTP/1.1"
        self.close_connection = True
        self.nginx_error(code)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):

        self.close_connection = True
        self.nginx_error(404)

    do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_POST

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        prefix = next((p for p in (SUB_PREFIX,) + EXTRA_PREFIXES if path.startswith(p)), None)
        if prefix is None:
            return self.nginx_error(404)
        sub_id = path[len(prefix):]
        is_asset = prefix == SUB_PREFIX and ASSET_PATTERN.fullmatch(sub_id)
        if not ID_PATTERN.fullmatch(sub_id) and not is_asset:
            return self.nginx_error(404)

        user_agent = self.headers.get("User-Agent", "")
        host = CONF.get("link_host") or self.headers.get("Host", CONF.get("host", ""))
        accept = self.headers.get("Accept", "")
        code, headers, body = panel_response(sub_id, presented_user_agent(user_agent), host, accept, prefix)
        if code is None:
            return self.nginx_error(502)

        content_type = headers.get("content-type", "")
        wants_clash = (bool(CLASH_CLIENT.search(user_agent)) or prefix != SUB_PREFIX) and "yaml" in content_type
        mihomo_core = wants_clash and not NOT_MIHOMO.search(user_agent)
        log(f"{user_agent[:80]!r} → "
            f"{'clash+awg' if mihomo_core else 'clash' if wants_clash else content_type.split(';')[0] or '?'}")

        if code == 200:
            try:
                body = self._transform(body, content_type, sub_id, user_agent, host, accept,
                                       prefix, wants_clash, mihomo_core)
            except (yaml.YAMLError, UnicodeError) as exc:
                log(f"подписку обработать не удалось: {exc}")

        self.send_response(code)
        for name in FORWARDED_HEADERS:
            if name not in headers:
                continue
            value = clean_userinfo(headers[name]) if name == "subscription-userinfo" else headers[name]
            if value and "\r" not in value and "\n" not in value:
                self.send_header(name.title(), value)
        self.send_header("Content-Length", str(len(body)))
        self._connection_header()
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _transform(self, body, content_type, sub_id, user_agent, host, accept,
                   prefix, wants_clash, mihomo_core):
        if wants_clash and not mihomo_core:
            body = drop_amnezia(body)
        elif mihomo_core and not sub_id.endswith(("-awg", "-tg")):

            awg_code, _, awg_body = panel_response(sub_id + "-awg", user_agent, host, accept, prefix)
            if awg_code == 200 and awg_body:
                body = attach_amnezia(body, awg_body)
        elif "json" in content_type or ("text/plain" in content_type and body.lstrip()[:1] in (b"[", b"{")):

            body = patch_xray_json(body, load_grace_map())
        elif "text/plain" in content_type:
            body = rewrite_link_list(body, load_grace_map())

        if wants_clash:
            if CONF.get("auto", True):
                body = insert_auto_group(body)
            if CONF.get("dns", True):
                body = ensure_dns(body)
        if mihomo_core:


            rules_data = read_rules()
            if rules_data:
                body = apply_split_routing(body, rules_data)
        return body


class SubscriptionServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    tls_context = None
    address_family = socket.AF_INET6 if ":" in CONF.get("listen", "") else socket.AF_INET

    def handle_error(self, request, client_address):
        pass





def _cli_rules_commands():
    """Обработка --routing-payload и --check-rules. True, если команда была."""
    argv = sys.argv
    if "--routing-payload" in argv:
        rules_data = read_rules(report=lambda m: print(m, file=sys.stderr))
        if not rules_data:
            raise SystemExit(1)
        print(panel_routing_profile(argv[argv.index("--routing-payload") + 1], rules_data))
        raise SystemExit(0)
    if "--check-rules" in argv:
        rules_data = read_rules(report=print)
        if rules_data:
            rules, direct_dns = rules_data
            print(f"Правил через VPN: {len(rules)}; DNS для остального: {', '.join(direct_dns) or 'системный'}")
            bad = []
            for kind in ("geosite", "geoip"):
                names = [value for rule_kind, value in rules if rule_kind == kind.upper()]
                bad.extend(f"{kind} {name}" for name in missing_geo_categories(kind, names))
            if bad:
                print("Нет такой категории: " + ", ".join(bad)
                      + ". Приложение не сможет запустить конфиг – исправьте или удалите эти строки.")
                raise SystemExit(2)
        raise SystemExit(0 if rules_data else 1)
    return False


def _watch_certificate(ctx, cert_path, key_path):

    last_mtime = os.path.getmtime(cert_path)
    while True:
        time.sleep(600)
        try:
            mtime = os.path.getmtime(cert_path)
            if mtime != last_mtime:
                ctx.load_cert_chain(cert_path, key_path)
                last_mtime = mtime
                log("сертификат перечитан после продления")
        except (OSError, ssl.SSLError) as exc:
            log(f"сертификат перечитать не удалось: {exc}")


def main():
    if _cli_rules_commands():
        return
    cert_path, key_path = CONF.get("cert"), CONF.get("key")
    if cert_path and _CREDS_DIR and os.path.exists(os.path.join(_CREDS_DIR, "cert.pem")):
        cert_path = os.path.join(_CREDS_DIR, "cert.pem")
        key_path = os.path.join(_CREDS_DIR, "key.pem")

    if not cert_path:
        listen = CONF.get("listen", "127.0.0.1")
        server = SubscriptionServer((listen, int(CONF["port"])), SubscriptionHandler)

        log(f"client-sub слушает {listen}:{CONF['port']} (TLS снимает nginx)")
        server.serve_forever()
        return

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.set_alpn_protocols(["http/1.1"])
    ctx.load_cert_chain(cert_path, key_path)
    threading.Thread(target=_watch_certificate, args=(ctx, cert_path, key_path), daemon=True).start()
    listen = CONF.get("listen", "0.0.0.0")
    server = SubscriptionServer((listen, int(CONF["port"])), SubscriptionHandler)
    server.tls_context = ctx
    log(f"client-sub слушает {listen}:{CONF['port']}")
    server.serve_forever()


if __name__ == "__main__":
    main()