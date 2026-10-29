from flask_restx import fields, Namespace
from app.utils import auth
from app import utils
from . import ARLResource

ns = Namespace('batch_export', description="批量导出")


batch_export_fields = ns.model('BatchExport',  {
    "task_id": fields.List(fields.String(description="任务 ID"), required=True),
})


@ns.route('/site/')
class BatchExportSite(ARLResource):

    @auth
    @ns.expect(batch_export_fields)
    def post(self):
        """
        站点批量导出
        """
        args = self.parse_args(batch_export_fields)
        task_id_list = args.pop("task_id", [])
        response = self.send_batch_export_file(task_id_list, "site")

        return response


@ns.route('/domain/')
class BatchExportDomain(ARLResource):

    @auth
    @ns.expect(batch_export_fields)
    def post(self):
        """
        域名批量导出
        """
        args = self.parse_args(batch_export_fields)
        task_id_list = args.get("task_id", [])

        response = self.send_batch_export_file(task_id_list, "domain")

        return response


@ns.route('/ip/')
class BatchExportIP(ARLResource):

    @auth
    @ns.expect(batch_export_fields)
    def post(self):
        """
        IP 批量导出
        """
        args = self.parse_args(batch_export_fields)
        task_id_list = args.get("task_id", [])

        response = self.send_batch_export_file(task_id_list, "ip")

        return response


@ns.route('/url/')
class BatchExportURL(ARLResource):

    @auth
    @ns.expect(batch_export_fields)
    def post(self):
        """
        URL 批量导出
        """
        args = self.parse_args(batch_export_fields)
        task_id_list = args.get("task_id", [])

        response = self.send_batch_export_file(task_id_list, "url")

        return response


@ns.route('/ip_port/')
class BatchExportIpPort(ARLResource):

    @auth
    @ns.expect(batch_export_fields)
    def post(self):
        """
        IP 端口批量导出
        """
        args = self.parse_args(batch_export_fields)
        task_id_list = args.get("task_id", [])

        items_set = set()
        for task_id in task_id_list:
            if not task_id:
                continue

            query = {"task_id": task_id}
            items = list(utils.conn_db('ip').find(query, {"ip": 1, "port_info": 1}))

            for item in items:
                curr_ip = item["ip"]
                for port_info in item.get("port_info", []):
                    items_set.add("{}:{}".format(curr_ip, port_info["port_id"]))

        response = self.send_file(items_set, "ip_port")

        return response


@ns.route('/domain_ip/')
class BatchExportDomainIP(ARLResource):

    @auth
    @ns.expect(batch_export_fields)
    def post(self):
        """
        子域名:IP 批量导出
        """
        args = self.parse_args(batch_export_fields)
        task_id_list = args.get("task_id", [])

        items_set = set()
        for task_id in task_id_list:
            if not task_id:
                continue

            query = {"task_id": task_id}
            # 取 ips 而非 record：record 存的是解析记录原值（CNAME 时是域名而非 IP），
            # 而 ips 是最终解析到的 IP 列表，A 记录与 CNAME 记录都已回填，可直接配对使用
            items = list(utils.conn_db('domain').find(query, {"domain": 1, "ips": 1, "_id": 0}))

            for item in items:
                curr_domain = item.get("domain")
                if not curr_domain:
                    continue
                for ip in item.get("ips") or []:
                    if ip:
                        items_set.add("{}:{}".format(curr_domain, ip))

        response = self.send_file(items_set, "domain_ip")

        return response


@ns.route('/cip/')
class BatchExportCIP(ARLResource):

    @auth
    @ns.expect(batch_export_fields)
    def post(self):
        """
        C段 批量导出
        """
        args = self.parse_args(batch_export_fields)
        task_id_list = args.get("task_id", [])

        response = self.send_batch_export_file(task_id_list, "cip")

        return response


@ns.route('/wih/')
class BatchExportWIH(ARLResource):

    @auth
    @ns.expect(batch_export_fields)
    def post(self):
        """
        WIH 批量导出
        """
        args = self.parse_args(batch_export_fields)
        task_id_list = args.get("task_id", [])

        response = self.send_batch_export_file(task_id_list, "wih")

        return response


scope_batch_export_fields = ns.model('ScopeBatchExport',  {
    "scope_id": fields.List(fields.String(description="资产组 ID")),
    "group_id": fields.String(description="集团ID")
})


from flask import request

def _get_scope_ids(self_obj, request_obj):
    scope_id_list = request_obj.json.get("scope_id", []) if request_obj.json else []
    group_id = request_obj.json.get("group_id", "") if request_obj.json else ""
    
    if not scope_id_list and not group_id:
        args = self_obj.parse_args(scope_batch_export_fields)
        scope_id_list = args.get("scope_id", [])
        group_id = args.get("group_id", "")
        
    if isinstance(scope_id_list, str):
        scope_id_list = [scope_id_list]
        
    # 优先使用显式选中的资产组列表；仅当未显式勾选特定资产组时，才根据 group_id 捞取集团下的全量资产组
    if not scope_id_list and group_id:
        if group_id == "unassigned":
            query = {"group_id": {"$in": [None, ""]}}
        else:
            query = {"group_id": group_id}
        scopes = utils.conn_db('asset_scope').find(query, {"_id": 1})
        scope_id_list = [str(s["_id"]) for s in scopes]
        
    return scope_id_list

@ns.route('/asset_ip/')
class BatchExportAssetIP(ARLResource):

    @auth
    @ns.expect(scope_batch_export_fields)
    def post(self):
        """
        资产组中IP批量导出
        """
        scope_id_list = _get_scope_ids(self, request)
        response = self.send_scope_batch_export_file(scope_id_list, "asset_ip")
        return response


@ns.route('/asset_domain/')
class BatchExportAssetDomain(ARLResource):

    @auth
    @ns.expect(scope_batch_export_fields)
    def post(self):
        """
        资产组中域名批量导出
        """
        scope_id_list = _get_scope_ids(self, request)
        response = self.send_scope_batch_export_file(scope_id_list, "asset_domain")
        return response


@ns.route('/asset_site/')
class BatchExportAssetSite(ARLResource):

    @auth
    @ns.expect(scope_batch_export_fields)
    def post(self):
        """
        资产组中站点批量导出
        """
        scope_id_list = _get_scope_ids(self, request)
        response = self.send_scope_batch_export_file(scope_id_list, "asset_site")
        return response


@ns.route('/asset_wih/')
class BatchExportAssetWIH(ARLResource):

    @auth
    @ns.expect(scope_batch_export_fields)
    def post(self):
        """
        资产组中 WIH 批量导出
        """
        scope_id_list = _get_scope_ids(self, request)
        response = self.send_scope_batch_export_file(scope_id_list, "asset_wih")
        return response
