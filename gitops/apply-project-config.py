#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
CFG_PATH = ROOT / "gitops" / "project.yaml"


def load_cfg() -> dict:
    if not CFG_PATH.is_file():
        print(f"error: missing {CFG_PATH}", file=sys.stderr)
        sys.exit(1)
    data = yaml.safe_load(CFG_PATH.read_text())
    if not isinstance(data, dict):
        sys.exit("error: project.yaml must be a mapping")
    return data


def _helm_chart_name(chart_dir: pathlib.Path) -> str:
    data = yaml.safe_load((chart_dir / "Chart.yaml").read_text())
    return str(data["name"])


def _discover_environments(chart_dir: pathlib.Path) -> list[str]:
    envs: list[str] = []
    for f in sorted(chart_dir.glob("values-*.yaml")):
        if f.name == "values.yaml":
            continue
        envs.append(f.stem.removeprefix("values-"))
    if not envs:
        sys.exit("error: no values-<env>.yaml overlays; cannot derive Argo environments")
    return envs


def _argocd_prefix_and_envs(c: dict) -> tuple[str, list[str], str]:
    ag = c.get("argocd") or {}
    chart_dir = ROOT / c["helm"]["chart_path"]
    prefix = str(ag.get("app_prefix") or c["app"]["image_name"])
    raw = ag.get("environments")
    if raw is None:
        envs = _discover_environments(chart_dir)
    elif isinstance(raw, list) and raw:
        envs = [str(e) for e in raw]
    else:
        sys.exit("error: argocd.environments must be a non-empty list when set")
    app_set_name = str(ag.get("application_set_name") or prefix)
    return prefix, envs, app_set_name


def github_env_lines(c: dict) -> str:
    az, app, h = c["azure"], c["app"], c["helm"]
    chart_dir = ROOT / h["chart_path"]
    prefix, _, _ = _argocd_prefix_and_envs(c)
    chart_nm = _helm_chart_name(chart_dir)
    ag = c.get("argocd") or {}
    lines = [
        f"ACR_NAME={az['acr_name']}",
        f"ACR_LOGIN_SERVER={az['acr_login_server']}",
        f"IMAGE_NAME={app['image_name']}",
        f"CHART={h['chart_path']}",
        f"HELM_VERSION={h['version']}",
        f"ARGO_APP_PREFIX={prefix}",
        f"HELM_CHART_NAME={chart_nm}",
    ]
    ag_ns = ag.get("namespace")
    if ag_ns:
        lines.append(f"VERIFY_ARGO_NS={ag_ns}")
    tid, sid, cid = az.get("tenant_id"), az.get("subscription_id"), az.get("client_id")
    if tid and sid and cid:
        lines.extend(
            [
                f"AZURE_TENANT_ID={tid}",
                f"AZURE_SUBSCRIPTION_ID={sid}",
                f"AZURE_CLIENT_ID={cid}",
            ]
        )
    aks = c.get("aks") or {}
    rg, cn = aks.get("resource_group"), aks.get("cluster_name")
    if rg and cn:
        lines.append(f"AKS_RESOURCE_GROUP={rg}")
        lines.append(f"AKS_CLUSTER_NAME={cn}")
        if aks.get("use_admin_kubeconfig"):
            lines.append("AKS_USE_ADMIN_KUBECONFIG=true")
    return "\n".join(lines) + "\n"


def _write_appprojects(path: pathlib.Path, prefix: str, envs: list[str]) -> None:
    docs: list[dict] = []
    for env in envs:
        docs.append(
            {
                "apiVersion": "argoproj.io/v1alpha1",
                "kind": "AppProject",
                "metadata": {"name": f"{prefix}-{env}", "namespace": "argocd"},
                "spec": {
                    "description": f"{prefix} - {env}",
                    "sourceRepos": ["*"],
                    "destinations": [
                        {
                            "name": "in-cluster",
                            "namespace": env,
                            "server": "https://kubernetes.default.svc",
                        }
                    ],
                    "namespaceResourceWhitelist": [{"group": "*", "kind": "*"}],
                    "clusterResourceWhitelist": [{"group": "", "kind": "Namespace"}],
                },
            }
        )
    docs.append(
        {
            "apiVersion": "argoproj.io/v1alpha1",
            "kind": "AppProject",
            "metadata": {"name": f"{prefix}-platform", "namespace": "argocd"},
            "spec": {
                "description": f"{prefix} - Argo CD platform manifests",
                "sourceRepos": ["*"],
                "destinations": [
                    {
                        "name": "in-cluster",
                        "namespace": "argocd",
                        "server": "https://kubernetes.default.svc",
                    }
                ],
                "namespaceResourceWhitelist": [{"group": "*", "kind": "*"}],
            },
        }
    )
    chunks = [yaml.dump(d, default_flow_style=False, sort_keys=False).rstrip() for d in docs]
    path.write_text("\n---\n".join(chunks) + "\n")


def _write_applicationset(
    path: pathlib.Path,
    prefix: str,
    envs: list[str],
    app_set_name: str,
    repo_url: str,
    chart_path: str,
) -> None:
    part_of = f"{prefix}-gitops"
    data = {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "ApplicationSet",
        "metadata": {
            "name": app_set_name,
            "namespace": "argocd",
            "labels": {"app.kubernetes.io/part-of": part_of},
        },
        "spec": {
            "generators": [{"list": {"elements": [{"env": e} for e in envs]}}],
            "template": {
                "metadata": {
                    "name": prefix + "-{{env}}",
                    "namespace": "argocd",
                    "finalizers": ["resources-finalizer.argocd.argoproj.io"],
                    "labels": {"app.kubernetes.io/part-of": part_of},
                },
                "spec": {
                    "project": prefix + "-{{env}}",
                    "source": {
                        "repoURL": repo_url,
                        "targetRevision": "{{env}}",
                        "path": chart_path,
                        "helm": {
                            "valueFiles": ["values.yaml", "values-{{env}}.yaml"],
                        },
                    },
                    "destination": {
                        "server": "https://kubernetes.default.svc",
                        "namespace": "{{env}}",
                    },
                    "syncPolicy": {
                        "automated": {"prune": True, "selfHeal": True},
                        "syncOptions": ["CreateNamespace=true"],
                    },
                },
            },
        },
    }
    path.write_text(yaml.dump(data, default_flow_style=False, sort_keys=False))


def _write_platform_application(
    path: pathlib.Path,
    prefix: str,
    repo_url: str,
    platform_branch: str,
    platform_path: str,
) -> None:
    data = {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Application",
        "metadata": {
            "name": "argocd-platform",
            "namespace": "argocd",
            "labels": {"app.kubernetes.io/part-of": prefix + "-gitops"},
        },
        "spec": {
            "project": f"{prefix}-platform",
            "source": {
                "repoURL": repo_url,
                "targetRevision": platform_branch,
                "path": platform_path,
            },
            "destination": {
                "server": "https://kubernetes.default.svc",
                "namespace": "argocd",
            },
            "syncPolicy": {"automated": {"prune": False, "selfHeal": True}},
        },
    }
    path.write_text(yaml.dump(data, default_flow_style=False, sort_keys=False))


def sync_files(c: dict) -> None:
    git_cfg = c["git"]
    repo_url = git_cfg["repo_url"]
    platform_branch = git_cfg["platform_branch"]
    platform_path = str(git_cfg.get("platform_path") or "gitops/argocd/platform")
    chart_path = c["helm"]["chart_path"]
    login = c["azure"]["acr_login_server"]
    image = c["app"]["image_name"]
    repo_full = f"{login}/{image}"

    prefix, envs, app_set_name = _argocd_prefix_and_envs(c)

    apps_dir = ROOT / "gitops/argocd/applications"
    _write_appprojects(apps_dir / "00-appprojects.yaml", prefix, envs)
    _write_applicationset(
        apps_dir / "applicationset.yaml",
        prefix,
        envs,
        app_set_name,
        repo_url,
        chart_path,
    )
    _write_platform_application(
        apps_dir / "argocd-platform-application.yaml",
        prefix,
        repo_url,
        platform_branch,
        platform_path,
    )

    values = ROOT / chart_path / "values.yaml"
    dv = yaml.safe_load(values.read_text())
    dv.setdefault("image", {})
    dv["image"]["repository"] = repo_full
    values.write_text(yaml.dump(dv, default_flow_style=False, sort_keys=False))


def _chart_dir(c: dict | None = None) -> pathlib.Path:
    c = c or load_cfg()
    p = ROOT / c["helm"]["chart_path"]
    if not p.is_dir():
        print(f"::error::Missing chart dir {p}", file=sys.stderr)
        sys.exit(1)
    return p


def helm_template_all() -> None:
    c = load_cfg()
    chart = _chart_dir(c)
    prefix, _, _ = _argocd_prefix_and_envs(c)
    for f in sorted(chart.glob("values-*.yaml")):
        if f.name == "values.yaml":
            continue
        env = f.stem.removeprefix("values-")
        subprocess.run(
            [
                "helm",
                "template",
                f"{prefix}-{env}",
                str(chart),
                "-f",
                str(chart / "values.yaml"),
                "-f",
                str(f),
            ],
            check=True,
        )


def helm_template_branch(branch: str) -> None:
    c = load_cfg()
    chart = _chart_dir(c)
    prefix, _, _ = _argocd_prefix_and_envs(c)
    overlay = chart / f"values-{branch}.yaml"
    if not overlay.is_file():
        print(f"::error::Missing {overlay}", file=sys.stderr)
        sys.exit(1)
    subprocess.run(
        [
            "helm",
            "template",
            f"{prefix}-{branch}",
            str(chart),
            "-f",
            str(chart / "values.yaml"),
            "-f",
            str(overlay),
        ],
        check=True,
    )


def patch_values_image() -> None:
    b, tag = os.environ["BRANCH"], os.environ["IMAGE_TAG"]
    repo = f'{os.environ["ACR_LOGIN_SERVER"]}/{os.environ["IMAGE_NAME"]}'
    chart = ROOT / os.environ["CHART"]
    p = chart / f"values-{b}.yaml"
    data = yaml.safe_load(p.read_text()) or {}
    data.setdefault("image", {})
    data["image"]["repository"] = repo
    data["image"]["tag"] = tag
    p.write_text(yaml.dump(data, default_flow_style=False, sort_keys=False))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--github-env", action="store_true")
    ap.add_argument("--sync-files", action="store_true")
    ap.add_argument("--helm-all", action="store_true")
    ap.add_argument("--helm-branch", metavar="BRANCH")
    ap.add_argument("--patch-values-image", action="store_true")
    args = ap.parse_args()
    if not any(
        [
            args.github_env,
            args.sync_files,
            args.helm_all,
            args.helm_branch,
            args.patch_values_image,
        ]
    ):
        ap.error("pass at least one action flag")
    c = load_cfg()
    if args.github_env:
        sys.stdout.write(github_env_lines(c))
    if args.sync_files:
        sync_files(c)
    if args.helm_all:
        helm_template_all()
    if args.helm_branch:
        helm_template_branch(args.helm_branch)
    if args.patch_values_image:
        patch_values_image()


if __name__ == "__main__":
    main()
