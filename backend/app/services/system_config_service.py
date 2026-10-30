import os
import re
import time
import requests

_UPDATE_CACHE = {
    "timestamp": 0,
    "data": None
}


def _credential_presence():
    """列出各三方凭据的配置状态，供前端渲染状态徽章。

    只返回布尔值与"是否来自 config.yaml 默认"标记，避免凭据经 GET 泄漏。
    """
    from app.config import Config
    from app.utils.conn import conn_db

    doc = conn_db('system_config').find_one({"_id": "general_config"}) or {}

    fields = {
        "fofa_key": ("FOFA_KEY", "fofa_key"),
        "zerozone_key": ("ZEROZONE_KEY", "zerozone_key"),
        "github_token": ("GITHUB_TOKEN", "github_token"),
        "tyc_id": ("TYC_ID", "tyc_id"),
        "tyc_token": ("TYC_TOKEN", "tyc_token"),
        "so_search_cookie": ("SO_SEARCH_COOKIE", "so_search_cookie"),
        "bing_search_cookie": ("BING_SEARCH_COOKIE", "bing_search_cookie"),
        "api_key": ("API_KEY", "api_key"),
        "webhook_token": ("WEB_HOOK_TOKEN", "webhook_token"),
        "dingding_access_token": ("DINGDING_ACCESS_TOKEN", "dingding_access_token"),
        "feishu_webhook": ("FEISHU_WEBHOOK", "feishu_webhook"),
        "wx_work_webhook": ("WX_WORK_WEBHOOK", "wx_work_webhook"),
        "tg_bot_token": ("TG_BOT_TOKEN", "tg_bot_token"),
        "email_username": ("EMAIL_USERNAME", "email_username"),
    }

    result = {}
    for label, (attr_name, db_key) in fields.items():
        try:
            value = getattr(Config, attr_name, "") or ""
        except Exception:
            value = ""
        configured = bool(str(value).strip())
        result[label] = {
            "configured": configured,
            "from_db": db_key in doc,
        }
    return result


def _security_policy_source():
    """返回安全策略当前生效值及其来源，供前端回显。

    显式区分 database / config_yaml 两种来源。
    """
    from app.config import Config
    from app.utils.conn import conn_db

    doc = conn_db('system_config').find_one({"_id": "security_policy"})
    if doc:
        return {
            "source": "database",
            "black_ips": doc.get("black_ips", []),
            "forbidden_domains": doc.get("forbidden_domains", []),
        }
    return {
        "source": "config_yaml",
        "black_ips": list(getattr(Config, "BLACK_IPS", []) or []),
        "forbidden_domains": list(getattr(Config, "FORBIDDEN_DOMAINS", []) or []),
    }


def dispatch_test_push(push_type: str, config: dict) -> dict:
    """执行单通道消息推送连通性测试"""
    from app.utils.push import dingding_send, feishu_send, wx_work_send, send_email, telegram_send
    from app.utils import http_req

    test_msg = "*【ARL-Next 系统通知】这是一条测试消息，您的推送配置一切正常。*"
    test_html = "<div><b>【ARL-Next 系统通知】</b>这是一条测试消息，您的推送配置一切正常。</div>"

    try:
        if push_type == "dingding":
            access_token = config.get("access_token")
            secret = config.get("secret")
            if not access_token or not secret:
                return {"code": 400, "message": "钉钉测试失败：Token 或 Secret 不能为空"}
            res = dingding_send(msg=test_msg, access_token=access_token, secret=secret, msgtype="markdown")
            if res.get("errcode") != 0:
                return {"code": 500, "message": f"钉钉推送失败: {res}"}
            return {"code": 200, "message": "钉钉测试推送成功"}

        elif push_type == "feishu":
            webhook_url = config.get("webhook_url")
            secret = config.get("secret")
            if not webhook_url or not secret:
                return {"code": 400, "message": "飞书测试失败：Webhook URL 或 Secret 不能为空"}
            res = feishu_send(msg=test_msg, webhook_url=webhook_url, secret=secret)
            if res.get("code") != 0:
                return {"code": 500, "message": f"飞书推送失败: {res}"}
            return {"code": 200, "message": "飞书测试推送成功"}

        elif push_type == "wxwork":
            webhook_url = config.get("webhook_url")
            if not webhook_url:
                return {"code": 400, "message": "企业微信测试失败：Webhook URL 不能为空"}
            res = wx_work_send(msg=test_msg, webhook_url=webhook_url)
            if res.get("errcode") != 0:
                return {"code": 500, "message": f"企业微信推送失败: {res}"}
            return {"code": 200, "message": "企业微信测试推送成功"}

        elif push_type == "telegram":
            bot_token = config.get("bot_token")
            chat_id = config.get("chat_id")
            if not bot_token or not chat_id:
                return {"code": 400, "message": "Telegram 测试失败：Bot Token 或 Chat ID 不能为空"}
            res = telegram_send(msg=test_msg, bot_token=bot_token, chat_id=chat_id)
            if not res.get("ok"):
                return {"code": 500, "message": f"Telegram 推送失败: {res}"}
            return {"code": 200, "message": "Telegram 测试推送成功"}

        elif push_type == "email":
            host = config.get("host")
            port = config.get("port")
            username = config.get("username")
            password = config.get("password")
            to = config.get("to")
            if not all([host, port, username, password, to]):
                return {"code": 400, "message": "邮件测试失败：所有邮件配置字段均不能为空"}
            try:
                port = int(port)
            except ValueError:
                return {"code": 400, "message": "邮件测试失败：端口必须为数字"}

            send_email(host=host, port=port, mail=username, password=password, to=to, title="[ARL-Next] 邮件测试推送", html=test_html)
            return {"code": 200, "message": "邮件测试推送成功"}

        elif push_type == "webhook":
            webhook_url = config.get("webhook_url")
            webhook_token = config.get("webhook_token")
            if not webhook_url:
                return {"code": 400, "message": "Webhook 测试失败：回调 URL 不能为空"}

            headers = {}
            if webhook_token:
                headers["Token"] = webhook_token

            payload = {
                "type": "test_push",
                "message": "这是一条 ARL-Next 系统的 Webhook 测试数据",
                "timestamp": time.time()
            }
            conn = http_req(webhook_url, method='post', json=payload, headers=headers, timeout=10)
            if conn.status_code >= 400:
                return {"code": 500, "message": f"Webhook 请求失败，状态码: {conn.status_code}, 响应: {conn.text[:200]}"}
            return {"code": 200, "message": "Webhook 测试回调成功"}

        else:
            return {"code": 400, "message": "不支持的测试推送类型"}

    except Exception as e:
        return {"code": 500, "message": f"测试推送过程中发生异常: {str(e)}"}


def get_local_version_str() -> str:
    """读取本地版本号"""
    candidates = [
        '/code/version.txt',
        'version.txt',
        os.path.join(os.path.dirname(__file__), '../../../version.txt')
    ]
    for p in candidates:
        if os.path.exists(p):
            try:
                with open(p, 'r', encoding='utf-8') as f:
                    v = f.read().strip()
                    if v:
                        return v
            except Exception:
                pass
    return '未知版本'


def get_local_changelog_section(tag: str) -> str:
    """从本地 CHANGELOG.md 中提取指定版本的更新说明"""
    candidates = [
        '/code/CHANGELOG.md',
        'CHANGELOG.md',
        os.path.join(os.path.dirname(__file__), '../../../CHANGELOG.md')
    ]
    for p in candidates:
        if os.path.exists(p):
            try:
                with open(p, 'r', encoding='utf-8') as f:
                    content = f.read()
                pattern = rf'##\s*\[?{re.escape(tag)}\]?.*?\n(.*?)(?=\n##\s*\[?v|\Z)'
                match = re.search(pattern, content, re.DOTALL | re.IGNORECASE)
                if match:
                    notes = match.group(1).strip()
                    return re.sub(r'\n---+\s*$', '', notes).strip()
            except Exception:
                pass
    return ''


def is_version_greater(v1: str, v2: str) -> bool:
    """比较版本号 v1 是否大于 v2 (支持 v1.2.0-fix1 等格式)"""
    if not v1 or not v2 or v1 == '未知版本' or v2 == '未知版本':
        return False

    clean1 = v1.lstrip('v').strip()
    clean2 = v2.lstrip('v').strip()

    base1, *suffix1 = clean1.split('-', 1)
    base2, *suffix2 = clean2.split('-', 1)

    parts1 = [int(x) for x in re.findall(r'\d+', base1)]
    parts2 = [int(x) for x in re.findall(r'\d+', base2)]

    for i in range(max(len(parts1), len(parts2))):
        n1 = parts1[i] if i < len(parts1) else 0
        n2 = parts2[i] if i < len(parts2) else 0
        if n1 > n2:
            return True
        if n1 < n2:
            return False

    s1 = suffix1[0] if suffix1 else ''
    s2 = suffix2[0] if suffix2 else ''

    if s1 and not s2:
        return True
    if not s1 and s2:
        return False
    if s1 and s2:
        nums1 = [int(x) for x in re.findall(r'\d+', s1)]
        nums2 = [int(x) for x in re.findall(r'\d+', s2)]
        num1 = nums1[0] if nums1 else 0
        num2 = nums2[0] if nums2 else 0
        if num1 != num2:
            return num1 > num2
        return s1 > s2
    return False


def check_system_update_info(force_refresh: bool = False) -> dict:
    """检查系统版本更新与获取更新日志（带内存缓存与本地回退）"""
    global _UPDATE_CACHE
    local_v = get_local_version_str()
    now = time.time()

    if not force_refresh and _UPDATE_CACHE["data"] and (now - _UPDATE_CACHE["timestamp"] < 3600):
        cached_data = _UPDATE_CACHE["data"].copy()
        cached_data["local_version"] = local_v
        cached_data["has_new_version"] = is_version_greater(cached_data.get("remote_version", ""), local_v)
        cached_data["is_cached"] = True
        return cached_data

    remote_v = None
    release_notes = ""
    html_url = "https://github.com/owl234/ARL-Next"
    published_at = ""
    is_offline = False

    headers = {
        "User-Agent": "ARL-Next-Server",
        "Accept": "application/vnd.github.v3+json"
    }

    try:
        resp = requests.get("https://api.github.com/repos/owl234/ARL-Next/releases/latest", headers=headers, timeout=4)
        if resp.status_code == 200:
            rel_data = resp.json()
            remote_v = rel_data.get("tag_name")
            release_notes = rel_data.get("body", "")
            html_url = rel_data.get("html_url", html_url)
            published_at = rel_data.get("published_at", "")
    except Exception:
        pass

    if not remote_v:
        try:
            tag_resp = requests.get("https://api.github.com/repos/owl234/ARL-Next/tags", headers=headers, timeout=4)
            if tag_resp.status_code == 200:
                tags = tag_resp.json()
                if tags and isinstance(tags, list):
                    valid_tags = [t.get("name") for t in tags if t.get("name")]
                    if valid_tags:
                        valid_tags.sort(key=lambda t: [int(x) for x in re.findall(r'\d+', t.split('-')[0])], reverse=True)
                        remote_v = valid_tags[0]
        except Exception:
            pass

    target_tag_for_notes = remote_v or local_v
    if not release_notes and target_tag_for_notes:
        release_notes = get_local_changelog_section(target_tag_for_notes)

    if not remote_v:
        remote_v = local_v
        is_offline = True
        if not release_notes:
            release_notes = get_local_changelog_section(local_v)

    has_new = is_version_greater(remote_v, local_v)

    result_data = {
        "local_version": local_v,
        "remote_version": remote_v,
        "has_new_version": has_new,
        "release_notes": release_notes,
        "html_url": html_url,
        "published_at": published_at,
        "is_cached": False,
        "is_offline": is_offline
    }

    _UPDATE_CACHE["timestamp"] = now
    _UPDATE_CACHE["data"] = result_data
    return result_data
