import functools
import re

from flask import request
from app.config import Config
from . import gen_md5, random_choices
from .conn import conn_db
from .time import curr_date

salt = 'arlsalt!@#'

# ==================== 角色与状态 ====================
# 角色：admin 可管理用户；user（普通用户）可用除「用户管理」外的全部功能
ROLE_ADMIN = "admin"
ROLE_USER = "user"

# 状态：active 正常；locked 已锁定（禁止登录，并立即吊销其已签发的会话）
STATUS_ACTIVE = "active"
STATUS_LOCKED = "locked"

VALID_ROLES = (ROLE_ADMIN, ROLE_USER)
VALID_STATUS = (STATUS_ACTIVE, STATUS_LOCKED)


class UserLockedError(Exception):
    """账号被锁定。与「账号密码错误」区分开，便于前端给出准确提示。"""
    pass


def get_user_role(user_doc):
    """读取用户角色。

    历史数据（引入多用户之前创建的账号）没有 role 字段，一律按管理员处理，
    否则升级后原有的 admin 会立刻失去用户管理权限。
    新建用户时接口会显式写入 role，不会走到这个兜底分支。
    """
    if not user_doc:
        return ROLE_USER
    return user_doc.get("role") or ROLE_ADMIN


def get_user_status(user_doc):
    if not user_doc:
        return STATUS_ACTIVE
    return user_doc.get("status") or STATUS_ACTIVE


def is_user_locked(user_doc):
    return get_user_status(user_doc) == STATUS_LOCKED


def user_login(username = None, password = None):
    if not username or not password:
        return

    query = {"username": username, "password": gen_md5(salt + password)}

    user = conn_db('user').find_one(query)
    if not user:
        return

    if is_user_locked(user):
        raise UserLockedError("该账号已被锁定，请联系管理员")

    item = {
        "username": username,
        "role": get_user_role(user),
        "token": gen_md5(random_choices(50)),
        "type": "login"
    }
    conn_db('user').update_one(
        {"_id": user["_id"]},
        {"$set": {"token": item["token"], "last_login": curr_date()}}
    )

    return item


def user_login_header():
    token = request.headers.get("Token") or request.args.get("token")

    if not Config.AUTH:
        return True

    item = {
        "username": "ARL-API",
        "token": Config.API_KEY,
        "type": "api"
    }


    if not token:
        return False

    if token == Config.API_KEY:
        return item


    data = conn_db('user').find_one({"token": token})
    if data:
        # 纵深防御：锁定账号即使仍持有 token 也一律拒绝（正常路径下锁定时已吊销 token）
        if is_user_locked(data):
            return False
        item["username"] = data.get("username")
        item["token"] = token
        item["type"] = "login"
        return item

    return False


def user_logout(token):
    if user_login_header():
        conn_db('user').update_one({"token": token}, {"$set": {"token": None}})


def user_refresh_token(token):
    if user_login_header():
        new_token = gen_md5(random_choices(50))
        conn_db('user').update_one({"token": token}, {"$set": {"token": new_token}})
        return new_token
    return None


def change_pass(token, old_password, new_password):
    query = {"token": token, "password": gen_md5(salt + old_password)}
    data = conn_db('user').find_one(query)
    if data:
        conn_db('user').update_one({"token": token}, {"$set": {"password": gen_md5(salt + new_password)}})
        return True
    else:
        return False


# ==================== 身份解析与权限校验 ====================

def current_user_profile():
    """解析当前请求的身份，返回 {username, role, status}；未登录返回 None。

    前端据此控制「用户管理」入口的可见性，并可在刷新页面后同步最新的角色变更。
    """
    user_info = user_login_header()
    if not user_info:
        return None

    if isinstance(user_info, dict) and user_info.get("type") == "api":
        # API KEY 是系统级密钥，沿用其「拥有全部权限」的既有语义，视为管理员
        return {
            "username": user_info.get("username"),
            "role": ROLE_ADMIN,
            "status": STATUS_ACTIVE,
        }

    user = conn_db('user').find_one({"token": request.headers.get("Token")})
    if not user:
        return None

    return {
        "username": user.get("username"),
        "role": get_user_role(user),
        "status": get_user_status(user),
    }


def admin_required(func):
    """管理员专用接口：普通用户一律拒绝（前端隐藏入口只是体验，这里才是权威校验）。"""
    ret_not_login = {
        "message": "not login",
        "code": 401,
        "data": {}
    }
    ret_forbidden = {
        "message": "无权限：该功能仅管理员可用",
        "code": 403,
        "data": {}
    }

    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        if not Config.AUTH:
            return func(*args, **kwargs)

        profile = current_user_profile()
        if not profile:
            return ret_not_login

        if profile.get("role") != ROLE_ADMIN:
            return ret_forbidden

        return func(*args, **kwargs)

    return wrapper


# ==================== 用户管理 ====================

def _admin_query(exclude_id=None):
    """匹配所有管理员：显式 role=admin，或历史数据没有 role 字段。"""
    query = {"$or": [
        {"role": ROLE_ADMIN},
        {"role": {"$in": [None, ""]}},
        {"role": {"$exists": False}},
    ]}
    if exclude_id is not None:
        query = {"$and": [query, {"_id": {"$ne": exclude_id}}]}
    return query


def _remaining_admin_count(exclude_id):
    """除指定账号外还剩几个管理员，用于「最后一个管理员」保护。"""
    return conn_db('user').count_documents(_admin_query(exclude_id))


def list_users(keyword=""):
    """用户列表（绝不返回密码字段）。"""
    query = {}
    keyword = (keyword or "").strip()
    if keyword:
        query["username"] = {"$regex": re.escape(keyword), "$options": "i"}

    items = []
    for user in conn_db('user').find(query, {"password": 0}).sort("_id", 1):
        items.append({
            "username": user.get("username"),
            "role": get_user_role(user),
            "status": get_user_status(user),
            "create_time": user.get("create_time") or "",
            "last_login": user.get("last_login") or "",
        })
    return items


def add_user(username, password, role=ROLE_USER):
    username = (username or "").strip()
    if not username:
        raise ValueError("用户名不能为空")
    if not password:
        raise ValueError("密码不能为空")
    if role not in VALID_ROLES:
        raise ValueError("角色取值非法")
    if conn_db('user').find_one({"username": username}):
        raise ValueError("用户名已存在")

    conn_db('user').insert_one({
        "username": username,
        "password": gen_md5(salt + password),
        "role": role,
        "status": STATUS_ACTIVE,
        "token": None,
        "create_time": curr_date(),
        "last_login": "",
    })


def update_user(operator, username, password=None, role=None):
    """编辑用户：可重置密码、调整角色。operator 为当前登录用户名。"""
    user = conn_db('user').find_one({"username": username})
    if not user:
        raise ValueError("用户不存在")

    updates = {}

    if password:
        updates["password"] = gen_md5(salt + password)

    if role and role != get_user_role(user):
        if role not in VALID_ROLES:
            raise ValueError("角色取值非法")
        if username == operator:
            # 允许自我降级会立刻把自己锁在用户管理之外，直接禁止；需要降级时由另一位管理员操作
            raise ValueError("不能修改当前登录账号自身的角色")
        if get_user_role(user) == ROLE_ADMIN and _remaining_admin_count(user["_id"]) == 0:
            raise ValueError("系统至少需要保留一个管理员，无法降级该账号")
        updates["role"] = role

    if not updates:
        return False

    conn_db('user').update_one({"_id": user["_id"]}, {"$set": updates})

    # 改密后强制该账号下线，需用新密码重新登录
    if "password" in updates:
        conn_db('user').update_one({"_id": user["_id"]}, {"$set": {"token": None}})

    return True


def delete_user(operator, username):
    user = conn_db('user').find_one({"username": username})
    if not user:
        raise ValueError("用户不存在")
    if username == operator:
        raise ValueError("不能删除当前登录的账号")
    if get_user_role(user) == ROLE_ADMIN and _remaining_admin_count(user["_id"]) == 0:
        raise ValueError("系统至少需要保留一个管理员，无法删除该账号")

    conn_db('user').delete_one({"_id": user["_id"]})


def set_user_status(operator, username, status):
    """锁定 / 解锁用户。"""
    if status not in VALID_STATUS:
        raise ValueError("状态取值非法")

    user = conn_db('user').find_one({"username": username})
    if not user:
        raise ValueError("用户不存在")
    if username == operator:
        raise ValueError("不能锁定当前登录的账号")
    if status == STATUS_LOCKED and get_user_role(user) == ROLE_ADMIN \
            and _remaining_admin_count(user["_id"]) == 0:
        raise ValueError("系统至少需要保留一个管理员，无法锁定该账号")

    updates = {"status": status}
    # 锁定时立即吊销会话，避免已登录的会话在锁定后继续可用
    if status == STATUS_LOCKED:
        updates["token"] = None

    conn_db('user').update_one({"_id": user["_id"]}, {"$set": updates})


def auth(func):
    ret = {
        "message": "not login",
        "code": 401,
        "data": {}
    }

    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        if Config.AUTH and not user_login_header():
            return  ret

        return func(*args, **kwargs)

    return wrapper
