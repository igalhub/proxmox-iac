// PX-013: real CI work on every push, not a decorative pipeline.
// SCM polling, not a webhook - this cluster has no public ingress for
// GitHub to reach. See docs/TICKETS.md PX-013 for the full rationale.
pipeline {
    agent {
        kubernetes {
            yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: terraform
      image: hashicorp/terraform:1.15
      command: ["sleep"]
      args: ["infinity"]
    - name: ansible
      image: python:3.12-slim
      command: ["sleep"]
      args: ["infinity"]
    - name: helm
      image: alpine/helm:3.21.2
      command: ["sleep"]
      args: ["infinity"]
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      command: ["sleep"]
      args: ["infinity"]
'''
        }
    }

    triggers {
        pollSCM('H/5 * * * *')
    }

    stages {
        stage('Terraform Validate') {
            steps {
                container('terraform') {
                    dir('terraform') {
                        sh 'terraform init -backend=false'
                        sh 'terraform validate'
                    }
                }
            }
        }

        stage('Ansible Lint') {
            steps {
                container('ansible') {
                    sh '''
                        pip install --quiet ansible ansible-lint
                        ansible-galaxy collection install -r ansible/requirements.yml
                        ansible-lint ansible/
                    '''
                }
            }
        }

        stage('Helm Chart Lint') {
            steps {
                container('helm') {
                    sh './scripts/helm-lint-values.sh'
                }
            }
        }

        // PX-014: builds and pushes the landing page image on every push -
        // no Docker daemon in this agent pod, so kaniko builds/pushes
        // without one, fitting the same ephemeral-pod-agent pattern as
        // the containers above. Tagged with the real commit SHA, never
        // "latest" - see docs/TICKETS.md PX-014 for the full rationale.
        stage('Build & Push Landing Image') {
            steps {
                container('kaniko') {
                    withCredentials([usernamePassword(
                        credentialsId: 'ghcr-push-token',
                        usernameVariable: 'REGISTRY_USER',
                        passwordVariable: 'REGISTRY_PASS'
                    )]) {
                        sh '''
                            mkdir -p /kaniko/.docker
                            AUTH=$(printf "%s:%s" "$REGISTRY_USER" "$REGISTRY_PASS" | base64 | tr -d '\\n')
                            cat > /kaniko/.docker/config.json <<CONFIG
{"auths":{"ghcr.io":{"auth":"$AUTH"}}}
CONFIG
                            /kaniko/executor \
                                --context="dir://${WORKSPACE}/landing" \
                                --dockerfile="${WORKSPACE}/landing/Dockerfile" \
                                --destination="ghcr.io/igalhub/proxmox-iac-landing:${GIT_COMMIT}"
                        '''
                    }
                }
            }
        }
    }
}
