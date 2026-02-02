pipeline {
  agent any

  options { timestamps() }

  parameters {
    choice(name: 'ACTION', choices: ['plan', 'apply', 'destroy'], description: 'Terraform action to run')
    booleanParam(name: 'AUTO_APPROVE', defaultValue: true, description: 'Auto-approve apply/destroy')

    // Your app (Weather-site) defaults. You can override at build time.
    string(name: 'APP_REPO_URL', defaultValue: 'https://github.com/Krish-venom/Weather-site.git', description: 'Git URL of the app to deploy')
    string(name: 'APP_BRANCH',   defaultValue: 'main', description: 'Branch to deploy')

    // SSH key fallback (only used if Terraform didn’t generate a PEM)
    string(name: 'SSH_KEY_CRED_ID', defaultValue: 'ssh_key', description: 'Jenkins SSH Private Key credential ID')
    string(name: 'ANSIBLE_PLAYBOOK', defaultValue: 'deploy.yml', description: 'Playbook under ansible-playbooks/ to run')
  }

  environment {
    TF_IN_AUTOMATION = 'true'
    TERRAFORM_DIR    = 'terraform'
    ANSIBLE_DIR      = 'ansible-playbooks'
    ANSIBLE_HOST_KEY_CHECKING = 'False'
    VENV     = '.venv-ansible'     // venv in workspace root
    APP_SRC  = 'app-src'           // folder to clone the app
    ARTIFACT = 'app.tar.gz'        // app bundle uploaded by Ansible
  }

  stages {
    stage('Checkout (infra repo)') {
      steps {
        checkout scm
        sh '''#!/usr/bin/env bash
set -euo pipefail
echo "PWD: $(pwd)"
ls -la
echo "TF dir:"; ls -la "${TERRAFORM_DIR}" || true
echo "Ansible dir:"; ls -la "${ANSIBLE_DIR}" || true
'''
      }
    }

    stage('Checkout Application (Weather-site)') {
      steps {
        // Use shell defaults so set -u never fails if params/environment aren't exported
        sh '''#!/usr/bin/env bash
set -euo pipefail
: "${APP_REPO_URL:=https://github.com/Krish-venom/Weather-site.git}"
: "${APP_BRANCH:=main}"
: "${APP_SRC:=app-src}"

echo "Cloning app: ${APP_REPO_URL} (branch=${APP_BRANCH})"
rm -rf "${APP_SRC}"
git clone --branch "${APP_BRANCH}" --depth 1 "${APP_REPO_URL}" "${APP_SRC}"
ls -la "${APP_SRC}" || true
'''
      }
    }

    stage('Package Application') {
      steps {
        sh '''#!/usr/bin/env bash
set -euo pipefail
: "${ARTIFACT:=app.tar.gz}"
: "${APP_SRC:=app-src}"

rm -f "${ARTIFACT}"
# Package the Weather-site (static HTML/CSS/JS) excluding .git
tar --exclude='.git' -czf "${ARTIFACT}" -C "${APP_SRC}" .
ls -lh "${ARTIFACT}"
'''
      }
    }

    stage('Terraform Init & Validate') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'aws_creds',
                                          usernameVariable: 'AWS_ACCESS_KEY_ID',
                                          passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
          dir(env.TERRAFORM_DIR) {
            sh '''#!/usr/bin/env bash
set -euo pipefail
test -n "$(ls -1 *.tf 2>/dev/null || true)" || { echo "No .tf files in $(pwd)"; exit 1; }

terraform fmt -recursive
terraform init -input=false
terraform validate
'''
          }
        }
      }
    }

    stage('Terraform Plan / Apply / Destroy') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'aws_creds',
                                          usernameVariable: 'AWS_ACCESS_KEY_ID',
                                          passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
          dir(env.TERRAFORM_DIR) {
            script {
              if (params.ACTION == 'plan') {
                sh '''#!/usr/bin/env bash
set -euo pipefail
terraform plan -no-color
'''
              } else if (params.ACTION == 'apply') {
                sh '''#!/usr/bin/env bash
set -euo pipefail
terraform apply -input=false -auto-approve -no-color
'''
              } else {
                sh '''#!/usr/bin/env bash
set -euo pipefail
terraform destroy -input=false -auto-approve -no-color
'''
              }
            }
          }
        }
      }
    }

    // Ansible is COMPULSORY after apply
    stage('Ansible Configure + Deploy (mandatory after apply)') {
      when { expression { params.ACTION == 'apply' } }
      steps {
        // 1) Build inventory from Terraform outputs and capture ABSOLUTE PEM path if generated
        dir(env.TERRAFORM_DIR) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo "python3 not found on agent. Install python3."; exit 1; }
python3 --version

terraform output -json > tf_outputs.json

python3 - <<'PY'
import json, sys
with open('tf_outputs.json') as f:
    data = json.load(f)
apache_ips = data.get('apache_public_ips', {}).get('value', []) or []
nginx_ips  = data.get('nginx_public_ips', {}).get('value', []) or []
ansible_user = (data.get('ansible_user', {}).get('value', 'ubuntu')
                if isinstance(data.get('ansible_user', {}), dict) else 'ubuntu')
if not apache_ips and not nginx_ips:
    print("ERROR: No instance IPs found in Terraform outputs.", file=sys.stderr)
    sys.exit(1)
lines = []
lines.append('[apache]')
for ip in apache_ips:
    lines.append(f'{ip} ansible_user={ansible_user} ansible_ssh_common_args="-o StrictHostKeyChecking=no"')
lines.append('')
lines.append('[nginx]')
for ip in nginx_ips:
    lines.append(f'{ip} ansible_user={ansible_user} ansible_ssh_common_args="-o StrictHostKeyChecking=no"')
open('ansible_inventory.ini', 'w').write("\\n".join(lines).strip()+"\\n")
PY

GEN_PEM="$(terraform output -raw generated_private_key_path 2>/dev/null || true)"
if [ -n "${GEN_PEM}" ] && [ -f "${GEN_PEM}" ]; then
  case "${GEN_PEM}" in
    /*) echo "${GEN_PEM}" > ../ANSIBLE_PEM_PATH.txt ;;
    *)  echo "$(pwd)/${GEN_PEM}" > ../ANSIBLE_PEM_PATH.txt ;;
  esac
else
  echo "" > ../ANSIBLE_PEM_PATH.txt
fi
'''
        }

        // 2) Create venv at workspace root and install Ansible (robust: ensurepip + virtualenv fallback)
        sh '''#!/usr/bin/env bash
set -euo pipefail

if [ ! -d "${WORKSPACE}/${VENV}" ]; then
  if python3 -c "import venv" 2>/dev/null; then
    python3 -m venv "${WORKSPACE}/${VENV}" || true
  fi
fi
if [ ! -d "${WORKSPACE}/${VENV}" ]; then
  python3 -m ensurepip --upgrade || true
  if python3 -c "import venv" 2>/dev/null; then
    python3 -m venv "${WORKSPACE}/${VENV}" || true
  fi
fi
if [ ! -d "${WORKSPACE}/${VENV}" ]; then
  python3 -m pip install --user --upgrade pip || true
  python3 -m pip install --user virtualenv || true
  USER_BASE="$(python3 -c "import site; print(site.USER_BASE)")"
  USER_BIN="${USER_BASE}/bin"
  if [ -x "${USER_BIN}/virtualenv" ]; then
    "${USER_BIN}/virtualenv" "${WORKSPACE}/${VENV}"
  else
    python3 -m virtualenv "${WORKSPACE}/${VENV}"
  fi
fi

test -x "${WORKSPACE}/${VENV}/bin/python" || { echo "venv Python missing"; exit 1; }
"${WORKSPACE}/${VENV}/bin/python" -m ensurepip --upgrade || true
"${WORKSPACE}/${VENV}/bin/python" -m pip install --upgrade pip
"${WORKSPACE}/${VENV}/bin/python" -m pip install --upgrade ansible

ls -la "${WORKSPACE}/${VENV}/bin"
test -x "${WORKSPACE}/${VENV}/bin/ansible-playbook" || { echo "ansible-playbook missing"; exit 1; }
'''

        // 3) Run Ansible using ABSOLUTE PATHS for everything
        script {
          def pemPathAbs       = readFile(file: 'ANSIBLE_PEM_PATH.txt').trim()
          def ansiblePlaybook  = "${env.WORKSPACE}/${env.VENV}/bin/ansible-playbook"
          def inventoryAbs     = "${env.WORKSPACE}/${env.TERRAFORM_DIR}/ansible_inventory.ini"
          def playbookAbs      = "${env.WORKSPACE}/${env.ANSIBLE_DIR}/${params.ANSIBLE_PLAYBOOK}"
          def artifactAbs      = "${env.WORKSPACE}/${env.ARTIFACT}"

          dir(env.TERRAFORM_DIR) {
            if (pemPathAbs) {
              sh """#!/usr/bin/env bash
set -euo pipefail
test -x "${ansiblePlaybook}" || { echo "ansible-playbook not found"; exit 1; }
test -f "${inventoryAbs}" || { echo "Inventory not found"; exit 1; }
test -f "${playbookAbs}" || { echo "Playbook not found"; exit 1; }
test -f "${artifactAbs}" || { echo "Artifact not found: ${artifactAbs}"; exit 1; }

"${ansiblePlaybook}" -i "${inventoryAbs}" \\
  --private-key "${pemPathAbs}" \\
  "${playbookAbs}" \\
  -e artifact_path="${artifactAbs}"
"""
            } else {
              withCredentials([sshUserPrivateKey(credentialsId: params.SSH_KEY_CRED_ID,
                                                keyFileVariable: 'SSH_KEY',
                                                usernameVariable: 'SSH_USER')]) {
                sh """#!/usr/bin/env bash
set -euo pipefail
test -x "${ansiblePlaybook}" || { echo "ansible-playbook not found"; exit 1; }
test -f "${inventoryAbs}" || { echo "Inventory not found"; exit 1; }
test -f "${playbookAbs}" || { echo "Playbook not found"; exit 1; }
test -f "${artifactAbs}" || { echo "Artifact not found: ${artifactAbs}"; exit 1; }

"${ansiblePlaybook}" -i "${inventoryAbs}" \\
  --private-key "${SSH_KEY}" \\
  "${playbookAbs}" \\
  -e artifact_path="${artifactAbs}"
"""
              }
            }
          }
        }

        // 4) Print & archive the web URLs
        dir(env.TERRAFORM_DIR) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
terraform output -json > tf_outputs.json
python3 - <<'PY'
import json, pathlib
out = json.load(open('tf_outputs.json'))
def get(key):
    v = out.get(key, {})
    return v.get('value', []) if isinstance(v, dict) else []
apache = get('apache_http_urls')
nginx  = get('nginx_http_urls')
lines = []
if apache:
    lines.append("Apache URLs:")
    lines += apache
    lines.append("")
if nginx:
    lines.append("Nginx URLs:")
    lines += nginx
    lines.append("")
content = "\\n".join(lines).strip() or "No public URLs found."
pathlib.Path("web-urls.txt").write_text(content+"\\n")
print(content)
PY
'''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: '**/terraform.tfstate*', allowEmptyArchive: true
      archiveArtifacts artifacts: 'terraform/ansible_inventory.ini', allowEmptyArchive: true
      archiveArtifacts artifacts: 'ANSIBLE_PEM_PATH.txt', allowEmptyArchive: true
      archiveArtifacts artifacts: 'terraform/web-urls.txt', allowEmptyArchive: true
    }
  }
}
