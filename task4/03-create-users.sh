#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${OUT_DIR:-./out}"
CTX="${CTX:-$(kubectl config current-context)}"
CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CTX\")].context.cluster}")"
SERVER="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$CLUSTER_NAME\")].cluster.server}")"
CA_DATA="$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$CLUSTER_NAME\")].cluster.certificate-authority-data}")"

mkdir -p "$OUT_DIR"

# В Git Bash на Windows это самый надёжный способ получить путь, понятный Docker Desktop:
# -m даёт формат C:/... (без переносов строк)
OUT_DIR_ABS="$(cygpath -m "$(cd "$OUT_DIR" && pwd)")"

create_key_and_csr_in_docker() {
  local USER="$1"
  local GROUP="$2"

  docker run --rm -v "${OUT_DIR_ABS}:/out" alpine:3.19 sh -lc "
    apk add --no-cache openssl >/dev/null 2>&1 &&
    openssl genrsa -out /out/${USER}.key 2048 >/dev/null 2>&1 &&
    openssl req -new -key /out/${USER}.key -out /out/${USER}.csr -subj '/CN=${USER}/O=${GROUP}' >/dev/null 2>&1
  "
}

create_user () {
  local USER="$1"
  local GROUP="$2"

  echo "==> Creating user: $USER (group: $GROUP)"

  # 1) key + csr (через docker openssl)
  create_key_and_csr_in_docker "$USER" "$GROUP"

  # base64 csr без переносов
  local CSR_B64
  CSR_B64="$(base64 < "$OUT_DIR/${USER}.csr" | tr -d '\n')"

  # 2) CSR object
  cat > "$OUT_DIR/${USER}-csr.yaml" <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER}
spec:
  request: ${CSR_B64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
  - client auth
EOF

  kubectl delete csr "${USER}" --ignore-not-found >/dev/null 2>&1
  kubectl apply -f "$OUT_DIR/${USER}-csr.yaml" >/dev/null

  # 3) approve csr
  kubectl certificate approve "${USER}" >/dev/null

  # 4) получить cert
  local CERT_B64
  CERT_B64="$(kubectl get csr "${USER}" -o jsonpath='{.status.certificate}')"
  if [[ -z "${CERT_B64}" ]]; then
    echo "ERROR: certificate was not issued for CSR ${USER}"
    kubectl describe csr "${USER}" || true
    exit 1
  fi
  echo "${CERT_B64}" | base64 -d > "$OUT_DIR/${USER}.crt"

  # 5) kubeconfig
  local KCFG="$OUT_DIR/kubeconfig-${USER}"
  cat > "$KCFG" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: ${SERVER}
    certificate-authority-data: ${CA_DATA}
users:
- name: ${USER}
  user:
    client-certificate-data: $(base64 < "$OUT_DIR/${USER}.crt" | tr -d '\n')
    client-key-data: $(base64 < "$OUT_DIR/${USER}.key" | tr -d '\n')
contexts:
- name: ${USER}@${CLUSTER_NAME}
  context:
    cluster: ${CLUSTER_NAME}
    user: ${USER}
current-context: ${USER}@${CLUSTER_NAME}
EOF

  echo "    -> created: $KCFG"
}

create_user "viewer1" "view-only"
create_user "operator-sales1" "ops-sales"
create_user "admin1" "platform-admins"

cat <<'EOT'

DONE ✅

Проверка:
  KUBECONFIG=./out/kubeconfig-viewer1 kubectl get ns
  KUBECONFIG=./out/kubeconfig-viewer1 kubectl get secret -n sales   # Forbidden (после ролей/биндингов)
  KUBECONFIG=./out/kubeconfig-operator-sales1 kubectl -n sales get pods
  KUBECONFIG=./out/kubeconfig-admin1 kubectl auth can-i '*' '*'

EOT
