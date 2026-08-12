# `proxmox-iac-ci` Jenkins job

`config.xml` in this directory is the real, live job config (fetched
back from Jenkins after creation, not hand-written) — a `Pipeline
script from SCM` job, not multibranch. Restore it after any Jenkins
data loss with:

```bash
JENKINS_URL="http://jenkins.lab.test"
JENKINS_USER="admin"
JENKINS_PASS="<from the jenkins-admin SealedSecret>"

COOKIE_JAR=$(mktemp)
CRUMB=$(curl -s -g -u "${JENKINS_USER}:${JENKINS_PASS}" -c "$COOKIE_JAR" \
  "${JENKINS_URL}/crumbIssuer/api/json" | python3 -c "import json,sys;print(json.load(sys.stdin)['crumb'])")

curl -s -g -u "${JENKINS_USER}:${JENKINS_PASS}" -b "$COOKIE_JAR" -H "Jenkins-Crumb: ${CRUMB}" \
  -H "Content-Type: application/xml" \
  --data-binary "@jenkins/jobs/proxmox-iac-ci/config.xml" \
  "${JENKINS_URL}/createItem?name=proxmox-iac-ci"

rm -f "$COOKIE_JAR"
```

## Prerequisite this job's XML does NOT cover

Before the job's first build, Jenkins' **global** Git SSH host-key
verification must be set — this is controller-wide config, not part of
any job, so it isn't in `config.xml` and is lost separately on any
Jenkins data loss (confirmed lost in PX-040's own recreation: reverted
to the default `KnownHostsFileVerificationStrategy` with no
`~/.ssh/known_hosts` at all). Without this, the first build fails at
checkout (`No ED25519 host key is known for github.com...`) — this is
exactly what PX-013 hit as "Bug 1", and why a controller-only
`known_hosts` fix isn't enough: build agents are fresh ephemeral pods
with no persistent filesystem, so only the global
`GitHostKeyVerificationConfiguration` setting (consulted by the
git-client plugin everywhere) covers every future agent pod.

Fetch GitHub's current host keys fresh (don't reuse an old copy — they
can rotate) and set them via the Script Console
(`/script` or the `/scriptText` REST endpoint):

```groovy
import org.jenkinsci.plugins.gitclient.GitHostKeyVerificationConfiguration
import org.jenkinsci.plugins.gitclient.verifier.ManuallyProvidedKeyVerificationStrategy

// Build this string from the current https://api.github.com/meta ssh_keys,
// one line per key, format: "github.com <keytype> <key>"
def keys = '''github.com ssh-ed25519 AAAA...
github.com ecdsa-sha2-nistp256 AAAA...
github.com ssh-rsa AAAA...'''

def config = GitHostKeyVerificationConfiguration.get()
config.setSshHostKeyVerificationStrategy(new ManuallyProvidedKeyVerificationStrategy(keys))
config.save()
```

## Credentials this job depends on

Both are sourced live from k8s Secrets via the Kubernetes Credentials
Provider plugin (`jenkins.io/credentials-type` label), **not** stored in
Jenkins' own filesystem — these survive a Jenkins pod/PV loss on their
own, no separate backup needed here:

- `jenkins-github-deploy-key` — SSH deploy key,
  `k8s/jenkins/jenkins-github-deploy-key-sealedsecret.yaml`
- `ghcr-push-token` — `k8s/jenkins/jenkins-ghcr-sealedsecret.yaml`

## Trigger

`pollSCM('H/5 * * * *')` comes from the `Jenkinsfile`'s own `triggers{}`
block (see repo root) — no separate job-level trigger config needed;
it's picked up automatically once the job runs once. SCM polling, not a
webhook, because this cluster has no public ingress for GitHub to
reach (PX-013).
