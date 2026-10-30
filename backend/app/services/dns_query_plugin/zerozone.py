import json
import time

from app.config import Config
from app.services.dns_query import DNSQueryBase
from app import utils


class Query(DNSQueryBase):
    """0.zone（零零信安）子域名查询插件。

    接口契约（与 yaklang 的 spacengine/zone 实现一致，已交叉核对）：
        POST https://0.zone/api/data/
        Content-Type: application/json
        body: {"query": ..., "query_type": ..., "page": ..., "pagesize": ..., "zone_key_id": ...}
        响应: {"code": 0, "message": "success", "data": [...]}，code 非 0 即失败

    鉴权用请求体里的 zone_key_id 字段（即控制台申请的 API KEY），不是 HTTP 头。
    API 申请：https://0.zone/applyParticulars?type=domain

    API KEY 走全局配置（Config.ZEROZONE_KEY，可在「系统设置 → 资产测绘与情报」填写），
    与 FOFA 一致——插件处只保留开关，不在插件配置里重复存放密钥。

    关于查询语法与返回字段：
        0.zone 的 query 采用 `字段==值` 语法（site 模块的官方示例为
        `ssl_info.detail==00sec.com`）。domain 模块的字段名与返回结构官方未完整公开，
        因此这里把「查询模板」做成可配置项（query_template），
        并在解析时对多个候选字段名做容错，避免接口细节变动就要改代码。
    """

    # 不同 query_type 返回的记录中，承载主机名的字段名并不统一。
    # 按优先级逐个尝试，取到第一个命中即用；DNSQueryBase.query() 之后还会再做
    # 「必须以目标域名结尾 + 合法域名 + 非黑名单」的过滤，故此处可以放宽取值。
    HOST_FIELDS = ("domain", "subdomain", "host", "hostname", "site", "url", "toplv_domain")

    def __init__(self):
        super(Query, self).__init__()
        self.source_name = "zerozone"
        self.api_url = "https://0.zone/api/data/"
        self.query_type = "domain"
        self.query_template = 'domain=="{target}"'
        self.page_size = 100
        self.max_page = 5
        self.zb_pay = False

    def init_key(self, query_type="domain", query_template='domain=="{target}"',
                 page_size=100, max_page=5, zb_pay=None, **_legacy):
        # **_legacy 吸收历史配置字段：本次改动前插件块里还有 api_key，
        # 已部署环境的 config.yaml 不会自动清理，多接收一个未知参数可避免
        # init_key 抛 TypeError 导致插件静默失效（密钥已统一走全局配置，此处忽略）
        self.query_type = query_type or "domain"
        self.query_template = query_template or 'domain=="{target}"'

        # 官方单页上限为 100，超出会被服务端拒绝
        try:
            self.page_size = max(1, min(int(page_size), 100))
        except (TypeError, ValueError):
            self.page_size = 100

        try:
            self.max_page = max(1, int(max_page))
        except (TypeError, ValueError):
            self.max_page = 5

        # 超出免费额度时自动扣 Z 币；未配置即不启用
        self.zb_pay = bool(zb_pay)

    @staticmethod
    def _normalize(value):
        """把 url / host 等各种形态统一成裸主机名。"""
        value = value.strip()
        if "//" in value:
            value = value.split("//", 1)[1]
        for sep in ("/", "?", "#"):
            value = value.split(sep, 1)[0]
        value = value.split(":", 1)[0]
        return value.strip("*.").lower()

    def _extract_hosts(self, item):
        """从单条记录里提取主机名。

        字段名不确定，故把所有候选字段都取出交给上层过滤——DNSQueryBase.query()
        会丢弃不以目标域名结尾、非法或命中黑名单的值，因此这里宁滥勿缺，
        避免因猜错字段名而整批漏数据。
        """
        if isinstance(item, str):
            return [self._normalize(item)]
        if not isinstance(item, dict):
            return []

        hosts = []
        for field in self.HOST_FIELDS:
            value = item.get(field)
            if isinstance(value, str) and value.strip():
                hosts.append(self._normalize(value))
        return hosts

    def sub_domains(self, target):
        # 密钥来自全局配置；未配置时直接抛错，避免发出一堆注定 401 的请求
        api_key = Config.ZEROZONE_KEY
        if not api_key:
            raise Exception(
                "{}: 未配置 0.zone API KEY，请在「系统设置 → 资产测绘与情报」的全局配置中填写".format(
                    self.source_name))

        query = self.query_template.replace("{target}", target)
        self.logger.debug("{} target:{} query:{}".format(self.source_name, target, query))

        results = []
        page = 1
        data = {}

        while page <= self.max_page:
            payload = {
                "query": query,
                "query_type": self.query_type,
                "page": page,
                "pagesize": self.page_size,
                "zone_key_id": api_key,
            }
            if self.zb_pay:
                payload["zb_pay"] = 1

            conn = utils.http_req(self.api_url, 'post', json=payload,
                                  timeout=(30.1, 100.1))
            if conn.status_code != 200:
                raise Exception("{}: HTTP {} {}".format(
                    self.source_name, conn.status_code, conn.text[:200]))

            try:
                data = conn.json()
            except Exception:
                raise Exception("{}: 响应非 JSON: {}".format(
                    self.source_name, conn.text[:200]))

            code = data.get("code")
            if code != 0:
                raise Exception("{} error: code={} message={}".format(
                    self.source_name, code, data.get("message")))

            items = data.get("data")
            if not isinstance(items, list) or not items:
                break

            for item in items:
                results.extend(self._extract_hosts(item))

            self.logger.debug("{} target:{} page:{} items:{} collected:{}".format(
                self.source_name, target, page, len(items), len(results)))

            # 不满一页说明已到末页
            if len(items) < self.page_size:
                break

            page += 1
            # 免费额度按请求次数计，翻页之间稍作停顿
            time.sleep(1)

        if not results:
            self.logger.debug("{} target:{} 未返回记录，原始响应：{}".format(
                self.source_name, target, json.dumps(data, ensure_ascii=False)[:500]))

        return list(set(results))
