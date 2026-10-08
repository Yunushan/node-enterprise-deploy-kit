#!/usr/bin/env python3
"""Render actual role templates into local data; never connect to a host."""
import json
import posixpath
import shlex
import shutil
import tempfile
from pathlib import Path, PureWindowsPath

import jinja2
import yaml


REPO_ROOT = Path(__file__).resolve().parents[2]
environment = jinja2.Environment(undefined=jinja2.StrictUndefined)
environment.filters.update(
    quote=lambda value: shlex.quote(str(value)),
    to_json=json.dumps,
    bool=lambda value: value if isinstance(value, bool) else str(value).lower() in ("true", "yes", "on", "1"),
    ternary=lambda value, yes, no: yes if value else no,
    dirname=posixpath.dirname,
    normpath=posixpath.normpath,
)
variables = yaml.safe_load((REPO_ROOT / "config/ansible/group_vars_all.example.yml").read_text(encoding="utf-8"))
templates = {
    platform: environment.from_string(
        (REPO_ROOT / f"ansible/roles/{platform}_node_service/templates/{filename}").read_text(encoding="utf-8")
    )
    for platform, filename in (("linux", "deploy.env.j2"), ("windows", "app.config.json.j2"))
}


def render(platform, **overrides):
    result = templates[platform].render(**(variables | overrides))
    if platform == "windows":
        return json.loads(result)
    parsed = {}
    for line in result.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, value = line.split("=", 1)
        tokens = shlex.split(value)
        assert len(tokens) <= 1, f"Unquoted shell assignment: {key}"
        parsed[key] = tokens[0] if tokens else ""
    return parsed


cases = (
    ("node", "standalone", "server.js", ["server.js"], ""),
    ("node", "next-start", "app.js", ["app.js"], ""),
    ("nextjs", "standalone", "server.js", ["server.js", ".next/BUILD_ID", ".next/static"], ""),
    ("next-js", "next-start", "node_modules/next/dist/bin/next", ["package.json", ".next/BUILD_ID", ".next", "node_modules/next/dist/bin/next"], "start -H 127.0.0.1"),
    ("reactjs", "standalone", "server.js", ["server.js", "build/index.html"], ""),
)
for platform in templates:
    for framework, mode, start, expected, arguments in cases:
        output = render(platform, node_deploy_app_framework=framework,
                        node_deploy_nextjs_deployment_mode=mode,
                        node_deploy_start_script=start,
                        node_deploy_package_expected_files=[],
                        node_deploy_node_arguments="", node_deploy_bind_address="127.0.0.1")
        actual_files = shlex.split(output["PACKAGE_EXPECTED_FILES"]) if platform == "linux" else output["PackageExpectedFiles"]
        assert actual_files == expected, (platform, framework, actual_files)
        assert output["NODE_ARGUMENTS" if platform == "linux" else "NodeArguments"] == arguments
    output = render(platform, node_deploy_app_framework="node",
                    node_deploy_package_expected_files=["app.js", "assets"],
                    node_deploy_node_arguments="--custom")
    actual_files = shlex.split(output["PACKAGE_EXPECTED_FILES"]) if platform == "linux" else output["PackageExpectedFiles"]
    assert actual_files == ["app.js", "assets"]
    assert output["NODE_ARGUMENTS" if platform == "linux" else "NodeArguments"] == "--custom"

output = render("linux", node_deploy_linux_healthcheck_state_dir="/private/var/lib/test-monitor")
assert output["HEALTHCHECK_LOG_DIR"] == "/private/var/lib/test-monitor/logs"
assert output["HEALTHCHECK_LOG_MAX_BYTES"] == "10485760"
assert output["APP_LOG_GENERATIONS"] == "7"
assert output['DEPLOYMENT_TRANSACTION_ROOT'] == '/var/lib/node-enterprise-deploy-kit/deployment-transactions'
output = render('linux', node_deploy_linux_deployment_transaction_root='/srv/private/persistent-journals')
assert output['DEPLOYMENT_TRANSACTION_ROOT'] == '/srv/private/persistent-journals'


def assert_deployed_runtime_policy(platform):
    """Materialize actual role copy tasks and exercise their relative dependencies."""
    role = REPO_ROOT / f"ansible/roles/{platform}_node_service"
    tasks = yaml.safe_load((role / "tasks/main.yml").read_text(encoding="utf-8"))
    windows = platform == "windows"
    module_prefix = "ansible.windows.win_" if windows else "ansible.builtin."
    deployment_root = "C:/verified-deployment" if windows else "/verified-deployment"
    task_variables = variables | {
        "node_deploy_windows_service_dir": deployment_root,
        "node_deploy_linux_deploy_dir": deployment_root,
    }
    for task in tasks:
        for key, value in task.get('ansible.builtin.set_fact', {}).items():
            if key == 'node_deploy_linux_incoming_config_path':
                task_variables[key] = environment.from_string(value).render(**task_variables)
    expected = (
        "scripts/dev/NodeRuntimePolicy.ps1" if windows else "scripts/linux/validate-node-runtime-policy.mjs",
        "config/node-runtime-policy.json",
    )
    created_directories = set()
    deploy_index = next(index for index, task in enumerate(tasks)
                        if task["name"] == f"Deploy {platform.title()} Node app using local orchestrator")
    temporary_root = REPO_ROOT / ".tmp"
    temporary_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"ansible-{platform}-policy-", dir=temporary_root) as directory:
        staged = Path(directory)
        for index, task in enumerate(tasks[:deploy_index]):
            file_task = task.get(module_prefix + "file")
            if file_task and file_task.get("state") == "directory":
                for item in task.get("loop", [None]):
                    if isinstance(item, str):
                        item = environment.from_string(item).render(**task_variables)
                    path = environment.from_string(file_task["path"]).render(**(task_variables | {"item": item}))
                    path = PureWindowsPath(path).as_posix() if windows else path
                    if path.startswith(deployment_root + "/"):
                        created_directories.add(path[len(deployment_root) + 1:])
            copy_task = task.get(module_prefix + "copy")
            if not copy_task:
                continue
            source = (role / "files" / copy_task["src"]).resolve()
            destination = environment.from_string(copy_task["dest"]).render(**task_variables)
            destination = PureWindowsPath(destination).as_posix() if windows else destination
            if not destination.startswith(deployment_root + "/"):
                continue
            relative = destination[len(deployment_root) + 1:].rstrip("/")
            if source.is_dir():
                shutil.copytree(source, staged / relative, dirs_exist_ok=True)
            elif relative in expected:
                assert index < deploy_index
                assert str(Path(relative).parent).replace("\\", "/") in created_directories, relative
                (staged / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, staged / relative)
        for relative in expected:
            assert (staged / relative).is_file(), f"{platform} role omits runtime dependency {relative}"
            assert (staged / relative).read_bytes() == (REPO_ROOT / relative).read_bytes(), relative
        policy = json.loads((staged / expected[1]).read_text(encoding="utf-8"))
        assert {line["major"] for line in policy["releaseLines"]} >= {22, 24, 26}
        preflight = staged / ("scripts/windows/Test-DeploymentPreflight.ps1" if windows else "scripts/linux/test-deployment-preflight.sh")
        assert preflight.is_file()
        assert expected[0].split("/")[-1] in preflight.read_text(encoding="utf-8")
        helper = (staged / expected[0]).read_text(encoding="utf-8")
        assert "node-runtime-policy.json" in helper if windows else "node-runtime-policy.json" in preflight.read_text(encoding="utf-8")


for platform in ("windows", "linux"):
    assert_deployed_runtime_policy(platform)


def assert_incoming_unix_config_preserves_installed_monitor():
    tasks = yaml.safe_load((REPO_ROOT / 'ansible/roles/linux_node_service/tasks/main.yml').read_text(encoding='utf-8'))
    resolve_index = next(index for index, task in enumerate(tasks)
                         if 'node_deploy_linux_incoming_config_path' in task.get('ansible.builtin.set_fact', {}))
    expression = tasks[resolve_index]['ansible.builtin.set_fact']['node_deploy_linux_incoming_config_path']
    project = variables['node_deploy_project_name']
    installed = f'/etc/node-enterprise-deploy-kit/{project}.env'
    incoming = f'/etc/node-enterprise-deploy-kit/incoming/{project}.env'
    cases = ((variables['node_deploy_linux_config_path'], incoming),
             (installed, incoming),
             (f'/etc/node-enterprise-deploy-kit/./{project}.env', incoming),
             (f'/etc/node-enterprise-deploy-kit/incoming/../{project}.env', incoming),
             ('/srv/private/incoming-release.env', '/srv/private/incoming-release.env'),
             ('', incoming))
    for configured, expected in cases:
        facts = variables | {'node_deploy_linux_config_path': configured}
        facts['node_deploy_linux_incoming_config_path'] = environment.from_string(expression).render(**facts)
        assert facts['node_deploy_linux_incoming_config_path'] == expected
        assert posixpath.normpath(expected) != installed
        rendered_destinations = []
        for index, task in enumerate(tasks):
            template = task.get('ansible.builtin.template')
            if template:
                assert index > resolve_index
                destination = environment.from_string(template['dest']).render(**facts)
                assert destination == expected
                rendered_destinations.append(destination)
                # Simulate the role's actual write target while preserving the
                # previous monitor bytes needed for transaction rollback.
                host_files = {installed: 'previous monitor configuration'}
                host_files[destination] = templates['linux'].render(**facts)
                assert host_files[installed] == 'previous monitor configuration'
            command = task.get('ansible.builtin.command', {})
            if task['name'] in ('Optionally install Linux dependencies', 'Deploy Linux Node app using local orchestrator'):
                arguments = [environment.from_string(argument).render(**facts) for argument in command['argv']]
                assert arguments[-1] == expected
            file_task = task.get('ansible.builtin.file', {})
            if file_task.get('state') == 'directory':
                directories = [environment.from_string(item).render(**facts) for item in task.get('loop', [])]
                assert posixpath.dirname(expected) in directories
        assert rendered_destinations == [expected]


assert_incoming_unix_config_preserves_installed_monitor()
print("Actual Ansible templates, Node policy deployment and incoming Unix config rollback isolation validated.")
