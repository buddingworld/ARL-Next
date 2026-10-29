from flask import request
from flask_restx import fields, Namespace
from app.utils import get_logger
from app import utils
from . import  ARLResource

ns = Namespace('user', description="管理员登录认证")

logger = get_logger()



login_fields = ns.model('LoginARL', {
    'username': fields.String(required=True, description="用户名"),
    'password': fields.String(required=True, description="密码"),
})


def build_ok(data):
    """成功响应。

    不能复用下面的 build_data：它把空列表/空字典也判为失败并返回 401，
    而「用户列表为空」是完全正常的状态。
    """
    return {
        "message": "success",
        "code": 200,
        "data": data
    }


def build_error(message, code=400):
    return {
        "message": message,
        "code": code,
        "data": {}
    }


@ns.route('/login')
class LoginARL(ARLResource):

    @ns.expect(login_fields)
    def post(self):
        """
        用户登录
        """
        args = self.parse_args(login_fields)

        try:
            data = utils.user_login(**args)
        except utils.UserLockedError as e:
            # 锁定与「账号密码错误」区分开，便于前端给出准确提示
            return build_error(str(e), code=403)

        return build_data(data)




@ns.route('/logout')
class LogoutARL(ARLResource):

    def get(self):
        """
        用户退出
        """
        token = request.headers.get("Token")
        utils.user_logout(token)

        return build_data({})

@ns.route('/refresh_token')
class RefreshTokenARL(ARLResource):
    @utils.auth
    def post(self):
        """
        刷新当前用户的 Token
        """
        token = request.headers.get("Token")
        new_token = utils.user_refresh_token(token)
        if new_token:
            return build_data({"token": new_token})
        return build_data(None)


@ns.route('/profile')
class UserProfileARL(ARLResource):

    @utils.auth
    def get(self):
        """
        当前登录用户的身份信息（角色 / 状态）

        前端据此控制「用户管理」入口的可见性，并在刷新页面后同步最新的角色变更。
        """
        return build_ok(utils.current_user_profile())


change_pass_fields = ns.model('ChangePassARL', {
    'old_password': fields.String(required=True, description="旧密码"),
    'new_password': fields.String(required=True, description="新密码"),
    'check_password': fields.String(required=True, description="确认密码"),
})


@ns.route('/change_pass')
class ChangePassARL(ARLResource):
    @ns.expect(change_pass_fields)
    def post(self):
        """
        密码修改
        """
        args = self.parse_args(change_pass_fields)
        ret = {
            "message": "success",
            "code": 200,
            "data": {}
        }
        token = request.headers.get("Token")

        if args["new_password"] != args["check_password"]:
            ret["code"] = 301
            ret["message"] = "新密码和确定密码不一致"
            return ret

        if not args["new_password"]:
            ret["code"] = 302
            ret["message"] = "新密码不能为空"
            return ret

        if utils.change_pass(token, args["old_password"], args["new_password"]):
            utils.user_logout(token)
        else:
            ret["message"] = "旧密码错误"
            ret["code"] = 303

        return ret


# ==================== 用户管理（仅管理员可用）====================
# 前端会隐藏普通用户的入口，但真正的权限边界由 admin_required 在后端把关。

user_list_fields = ns.model('UserListARL', {
    'keyword': fields.String(required=False, description="按用户名模糊查询"),
})


@ns.route('/list/')
class UserListARL(ARLResource):

    @utils.admin_required
    @ns.expect(user_list_fields)
    def get(self):
        """
        用户列表（支持按用户名模糊查询）
        """
        args = self.parse_args(user_list_fields, location='args')
        return build_ok(utils.list_users(args.get("keyword") or ""))


user_add_fields = ns.model('UserAddARL', {
    'username': fields.String(required=True, description="用户名"),
    'password': fields.String(required=True, description="密码"),
    'role': fields.String(required=False, description="角色：admin（管理员）/ user（普通用户）"),
})


@ns.route('/add/')
class UserAddARL(ARLResource):

    @utils.admin_required
    @ns.expect(user_add_fields)
    def post(self):
        """
        新增用户
        """
        args = self.parse_args(user_add_fields)
        try:
            utils.add_user(args["username"], args["password"],
                           args.get("role") or utils.ROLE_USER)
        except ValueError as e:
            return build_error(str(e))

        return build_ok({})


user_update_fields = ns.model('UserUpdateARL', {
    'username': fields.String(required=True, description="目标用户名"),
    'password': fields.String(required=False, description="新密码，留空表示不修改"),
    'role': fields.String(required=False, description="角色，留空表示不修改"),
})


@ns.route('/update/')
class UserUpdateARL(ARLResource):

    @utils.admin_required
    @ns.expect(user_update_fields)
    def post(self):
        """
        编辑用户（重置密码 / 调整角色）
        """
        args = self.parse_args(user_update_fields)
        operator = (utils.current_user_profile() or {}).get("username")

        try:
            changed = utils.update_user(operator, args["username"],
                                        args.get("password"), args.get("role"))
        except ValueError as e:
            return build_error(str(e))

        return build_ok({"changed": bool(changed)})


user_delete_fields = ns.model('UserDeleteARL', {
    'username': fields.String(required=True, description="待删除的用户名"),
})


@ns.route('/delete/')
class UserDeleteARL(ARLResource):

    @utils.admin_required
    @ns.expect(user_delete_fields)
    def post(self):
        """
        删除用户
        """
        args = self.parse_args(user_delete_fields)
        operator = (utils.current_user_profile() or {}).get("username")

        try:
            utils.delete_user(operator, args["username"])
        except ValueError as e:
            return build_error(str(e))

        return build_ok({})


user_status_fields = ns.model('UserStatusARL', {
    'username': fields.String(required=True, description="目标用户名"),
    'status': fields.String(required=True, description="目标状态：locked（锁定）/ active（解锁）"),
})


@ns.route('/lock/')
class UserLockARL(ARLResource):

    @utils.admin_required
    @ns.expect(user_status_fields)
    def post(self):
        """
        锁定 / 解锁用户
        """
        args = self.parse_args(user_status_fields)
        operator = (utils.current_user_profile() or {}).get("username")

        try:
            utils.set_user_status(operator, args["username"], args["status"])
        except ValueError as e:
            return build_error(str(e))

        return build_ok({})


def build_data(data):
    ret = {
        "message": "success",
        "code": 200,
        "data": {}
    }

    if data:
        ret["data"] = data
    else:
        ret["code"] = 401

    return ret
