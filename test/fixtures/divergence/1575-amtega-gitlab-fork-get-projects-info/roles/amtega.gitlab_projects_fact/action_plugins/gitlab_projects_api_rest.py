#!/usr/bin/python
# Make coding more python3-ish, this is required for contributions to Ansible
from __future__ import (absolute_import, division, print_function)
__metaclass__ = type

from ansible.plugins.action import ActionBase
from ansible.plugins.filter.core import regex_replace
from ansible.utils.display import Display
from urllib.parse import quote


class ActionModule(ActionBase):
    _display = Display()

    def _get_task_var(self, name, default=None):
        """Get templated task variable"""

        if name in self._task_vars:
            ret = self._templar.template(self._task_vars.get(name))
        else:
            ret = default

        return ret

    def _get_error(self, result):
        """Raise API REST error"""

        output = dict(
                    failed=True,
                    msg="Operation in {0} failed: {1}".format(
                        result["url"],
                        result["json"].get("msg",
                                           result["json"].get("detail",
                                                              result["msg"])))
        )

        return output

    def _call(self):
        """Call tower API REST"""

        try:
            server = self._get_task_var("gitlab_projects_fact_server")

            api_version = self._get_task_var(
                                            "gitlab_projects_fact_api_version")

            token = self._get_task_var("gitlab_projects_fact_token")

            max_page_size = self._get_task_var(
                                        "gitlab_projects_fact_max_page_size")

            parameters = self._task.args.get("parameters", {})

            validate_certs = self._get_task_var(
                                        "gitlab_projects_fact_validate_certs")

            timeout = self._get_task_var("gitlab_projects_timeout")

            status_code = self._get_task_var("status_code",
                                             [200, 201, 202, 203, 204])

            # Setup path with keyset baseds pagination and parameters

            path = "/api/v{api_version}/projects" \
                   + "?pagination=keyset" \
                   + "&order_by=id" \
                   + "&per_page={max_page_size}"

            path = path.format(api_version=api_version,
                               max_page_size=max_page_size)

            for parameter in parameters:
                path = path + "&{parameter}={value}".format(
                                        parameter=parameter,
                                        value=quote(parameters[parameter]))

            url = "{server}{path}".format(server=server, path=path)

            # Call the API rest and iterate all the pages returned

            json = []
            while url != "":
                # Setup URI module args

                uri_args = dict(
                    url=url,
                    method="GET",
                    headers={
                        "Private-Token": token,
                        "Content-Type": "application/json"
                    },
                    validate_certs=validate_certs,
                    follow_redirects="all",
                    return_content=True,
                    status_code=status_code,
                    timeout=timeout,
                )

                # Call URI module

                result = self._execute_module(module_name='uri',
                                              module_args=uri_args,
                                              task_vars=self._task_vars,
                                              tmp=self._tmp)

                self._display.vvv(
                              "{action} result: {result}"
                              .format(action=self._task.action, result=result))

                # Handle failed return status

                if result.get("failed", False):
                    return self._get_error(result)

                # Combine results from multiple pages

                json += result.get("json", [])

                # Get next page

                url = regex_replace(result.get("link", ""), "<(.*)>.*", "\\1")

            return dict(json=json,
                        status=result["status"],
                        msg=result["msg"])
        except Exception:
            return self._get_error(result)

    def run(self, tmp=None, task_vars=None):
        """Run the action module"""

        super(ActionModule, self).run(tmp, task_vars)
        self._tmp = tmp
        self._task_vars = task_vars

        try:
            result = self._call()
        finally:
            self._remove_tmp_path(self._connection._shell.tmpdir)

        return result
