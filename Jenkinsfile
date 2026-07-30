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
    }
}
