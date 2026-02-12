#!/usr/bin/env bash
set -euo pipefail

NS="task5"

echo "[1/5] Create namespace (if not exists): ${NS}"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

echo "[2/5] Start 4 services (pods) + expose them as Services"

# front-end
kubectl -n "${NS}" run front-end-app \
  --image=nginx \
  --labels=role=front-end \
  --port=80 \
  --expose \
  --restart=Never \
  --dry-run=client -o yaml | kubectl apply -f -

# back-end-api
kubectl -n "${NS}" run back-end-api-app \
  --image=nginx \
  --labels=role=back-end-api \
  --port=80 \
  --expose \
  --restart=Never \
  --dry-run=client -o yaml | kubectl apply -f -

# admin-front-end
kubectl -n "${NS}" run admin-front-end-app \
  --image=nginx \
  --labels=role=admin-front-end \
  --port=80 \
  --expose \
  --restart=Never \
  --dry-run=client -o yaml | kubectl apply -f -

# admin-back-end-api
kubectl -n "${NS}" run admin-back-end-api-app \
  --image=nginx \
  --labels=role=admin-back-end-api \
  --port=80 \
  --expose \
  --restart=Never \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[3/5] (Optional) Start secret pod (isolated by secret-deny-all NetworkPolicy)"
kubectl -n "${NS}" run secret-app \
  --image=nginx \
  --labels=role=secret \
  --port=80 \
  --expose \
  --restart=Never \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[4/5] Apply NetworkPolicies"
kubectl apply -f default-deny-ingress.yaml
kubectl apply -f non-admin-api-allow.yaml
kubectl apply -f admin-api-allow.yaml
kubectl apply -f secret-deny-all.yaml

echo "[5/5] Show results"
kubectl -n "${NS}" get pods -o wide
kubectl -n "${NS}" get svc
kubectl -n "${NS}" get networkpolicy
