#!/usr/bin/env bash
# Post-deploy: rollout + Argo health + in-cluster /api/healthz; Argo rollback if checks fail.
# Defaults target the main env; override with VERIFY_NAMESPACE, VERIFY_ARGO_APP, VERIFY_DEPLOYMENT.
set -euo pipefail

NS_APP="${VERIFY_NAMESPACE:-main}"
P="${ARGO_APP_PREFIX:-rahi-chat-app}"
C="${HELM_CHART_NAME:-rahi-chat-app}"
DEPLOY="${VERIFY_DEPLOYMENT:-${P}-main-${C}}"
ARGO_APP="${VERIFY_ARGO_APP:-${P}-main}"
ARGO_NS="${VERIFY_ARGO_NS:-argocd}"
ROLLOUT_TIMEOUT="${VERIFY_ROLLOUT_TIMEOUT:-5m}"
ARGO_WAIT_SEC="${VERIFY_ARGO_WAIT_SEC:-600}"
STEP="${VERIFY_POLL_SEC:-15}"
SKIP_ROLLBACK="${VERIFY_SKIP_ROLLBACK:-0}"
SMOKE_JOB="smoke-${GITHUB_RUN_ID:-local}"

rollback() {
  if [[ "$SKIP_ROLLBACK" == "1" ]]; then
    echo "::warning::VERIFY_SKIP_ROLLBACK=1 — not rolling back."
    return 0
  fi
  echo "::error::Attempting Argo CD rollback: $ARGO_APP"
  if ! command -v argocd >/dev/null 2>&1; then
    echo "::warning::argocd CLI missing — set up rollback manually or fix install step."
    return 1
  fi
  export ARGOCD_NAMESPACE="${ARGO_NS:-argocd}"
  if ! kubectl get configmap argocd-cm -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    echo "::warning::Skip Argo rollback: no argocd-cm in namespace \"$ARGOCD_NAMESPACE\". Set \"argocd.namespace\" in gitops/project.yaml to the namespace where Argo CD is installed."
    return 0
  fi
  if ! argocd login --core; then
    echo "::warning::argocd login --core failed; check RBAC to ConfigMaps in $ARGOCD_NAMESPACE."
    return 1
  fi
  if ! argocd app rollback "$ARGO_APP" --app-namespace "$ARGOCD_NAMESPACE"; then
    echo "::warning::Rollback CLI failed (RBAC, or no history yet)."
  fi
}

echo "Initial pause for Git + Argo to reconcile..."
sleep "${VERIFY_INITIAL_SLEEP:-35}"

echo "Waiting for Deployment rollout ($DEPLOY / $NS_APP)..."
if ! kubectl rollout status "deployment/$DEPLOY" -n "$NS_APP" --timeout="$ROLLOUT_TIMEOUT"; then
  echo "::error::Rollout failed or timed out."
  echo "::group::Debug: pods / events in $NS_APP"
  kubectl get pods -n "$NS_APP" -l "app.kubernetes.io/instance=${P}-${NS_APP}" -o wide 2>/dev/null || kubectl get pods -n "$NS_APP" -o wide || true
  pod=$(kubectl get pods -n "$NS_APP" -l "app.kubernetes.io/instance=${P}-${NS_APP}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${pod:-}" ]]; then
    echo "--- logs $pod (current) ---"
    kubectl logs -n "$NS_APP" "$pod" -c app --tail=80 2>/dev/null || kubectl logs -n "$NS_APP" "$pod" --tail=80 2>/dev/null || true
  fi
  kubectl describe deployment "$DEPLOY" -n "$NS_APP" 2>/dev/null | tail -40 || true
  kubectl get events -n "$NS_APP" --sort-by='.lastTimestamp' 2>/dev/null | tail -25 || true
  echo "::endgroup::"
  rollback || true
  exit 1
fi

health="Unknown"
sync="Unknown"
elapsed=0
degraded=0
progressing_debug=0
argo_fast_path=0
while [[ $elapsed -lt "$ARGO_WAIT_SEC" ]]; do
  health=$(kubectl get application "$ARGO_APP" -n "$ARGO_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || echo Unknown)
  sync=$(kubectl get application "$ARGO_APP" -n "$ARGO_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Unknown)
  echo "Argo CD app $ARGO_APP: health=$health sync=$sync (${elapsed}s / ${ARGO_WAIT_SEC}s)"
  if [[ "$health" == "Healthy" && "$sync" == "Synced" ]]; then
    break
  fi
  if [[ "$health" == "Degraded" ]]; then
    degraded=1
    break
  fi
  # Argo health often lags after rollout; if Deployment is Available and fully ready, continue.
  if [[ "$sync" == "Synced" && "$health" == "Progressing" && $elapsed -ge 30 ]]; then
    avail=$(kubectl get deployment "$DEPLOY" -n "$NS_APP" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
    want=$(kubectl get deployment "$DEPLOY" -n "$NS_APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    have=$(kubectl get deployment "$DEPLOY" -n "$NS_APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [[ "$avail" == "True" && -n "$want" && "$want" != "0" && "$have" == "$want" ]]; then
      echo "::notice::Deployment $DEPLOY is Available (${have}/${want} ready); Argo still reports Progressing — continuing to smoke test."
      argo_fast_path=1
      break
    fi
  fi
  if [[ "$health" == "Progressing" && $elapsed -ge 120 && $progressing_debug -eq 0 ]]; then
    progressing_debug=1
    echo "::group::Debug: Argo still Progressing after ${elapsed}s (pods / deployment)"
    kubectl get pods -n "$NS_APP" -o wide 2>/dev/null || true
    kubectl describe deployment "$DEPLOY" -n "$NS_APP" 2>/dev/null | tail -35 || true
    echo "::endgroup::"
  fi
  sleep "$STEP"
  elapsed=$((elapsed + STEP))
done

if [[ "$degraded" == 1 ]]; then
  echo "::error::Argo reports Degraded."
  rollback || true
  exit 1
fi

if [[ "$argo_fast_path" != "1" && ( "$health" != "Healthy" || "$sync" != "Synced" ) ]]; then
  echo "::error::Timeout waiting for Healthy+Synced (health=$health sync=$sync)."
  rollback || true
  exit 1
fi

APP_PORT="${VERIFY_APP_PORT:-8081}"
# Prefer ready Pod IP (same path as probes); Endpoints first, then pod list (EndpointSlice / timing gaps).
SMOKE_IP=$(kubectl get endpoints "$DEPLOY" -n "$NS_APP" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
if [[ -z "${SMOKE_IP}" ]]; then
  SMOKE_IP=$(kubectl get pods -n "$NS_APP" -l "app.kubernetes.io/instance=${P}-${NS_APP}" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
fi
if [[ -n "${SMOKE_IP}" ]]; then
  if [[ "${SMOKE_IP}" == *:* ]]; then
    URL="http://[${SMOKE_IP}]:${APP_PORT}/api/healthz"
    CURL_FAMILY="-6"
  else
    URL="http://${SMOKE_IP}:${APP_PORT}/api/healthz"
    CURL_FAMILY="-4"
  fi
  echo "Smoke Job: GET $URL (direct pod IP, deployment $DEPLOY)"
else
  URL="http://${DEPLOY}.${NS_APP}.svc.cluster.local:${APP_PORT}/api/healthz"
  CURL_FAMILY="-4"
  echo "Smoke Job: GET $URL (Service DNS — no pod IP yet)"
fi
kubectl delete job -n "$NS_APP" "$SMOKE_JOB" --ignore-not-found >/dev/null 2>&1 || true

# Job command[] must be all YAML strings: bare "Accept: ..." becomes a mapping (object) and breaks the API.
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${SMOKE_JOB}
  namespace: ${NS_APP}
spec:
  ttlSecondsAfterFinished: 120
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: curl
          image: curlimages/curl:8.5.0
          command:
            - "curl"
            - "${CURL_FAMILY}"
            - "-sfS"
            - "--connect-timeout"
            - "30"
            - "-H"
            - "Accept: application/json"
            - "${URL}"
EOF

smoke_ok=0
for _ in $(seq 1 40); do
  succeeded=$(kubectl get job "$SMOKE_JOB" -n "$NS_APP" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")
  failed=$(kubectl get job "$SMOKE_JOB" -n "$NS_APP" -o jsonpath='{.status.failed}' 2>/dev/null || echo "")
  if [[ "${succeeded:-0}" == "1" ]]; then
    smoke_ok=1
    break
  fi
  if [[ -n "${failed:-}" && "${failed:-0}" -ge 1 ]] 2>/dev/null; then
    echo "::error::Smoke Job failed."
    kubectl logs -n "$NS_APP" "job/$SMOKE_JOB" --all-containers=true 2>/dev/null || true
    echo "::group::Debug: image / endpoints / pods ($NS_APP)"
    kubectl get deployment "$DEPLOY" -n "$NS_APP" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null && echo || true
    kubectl get endpoints "$DEPLOY" -n "$NS_APP" -o yaml 2>/dev/null | head -40 || true
    kubectl get pods -n "$NS_APP" -l "app.kubernetes.io/instance=${P}-${NS_APP}" -o wide 2>/dev/null || true
    echo "::endgroup::"
    kubectl delete job -n "$NS_APP" "$SMOKE_JOB" --ignore-not-found || true
    rollback || true
    exit 1
  fi
  sleep 3
done

if [[ "$smoke_ok" != "1" ]]; then
  echo "::error::Smoke Job timed out."
  kubectl logs -n "$NS_APP" "job/$SMOKE_JOB" --all-containers=true 2>/dev/null || true
  kubectl delete job -n "$NS_APP" "$SMOKE_JOB" --ignore-not-found || true
  rollback || true
  exit 1
fi
echo "Smoke Job succeeded."

kubectl delete job -n "$NS_APP" "$SMOKE_JOB" --ignore-not-found || true
echo "Deploy verify OK (rollout + Argo + smoke)."
