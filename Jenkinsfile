// Root (superproject) CI + release pipeline. This is the single release authority.
//
//  - Branch / PR (a submodule-pointer change): initialize the tag/commit-pinned private submodules
//    with the read-only CI key and run the cross-stack Playwright journey. NO publish, NO deploy.
//  - Root tag vX.Y.Z (strict SemVer): re-run the complete backend, frontend and cross-stack checks
//    against the pinned commits, build the backend JAR and Angular distribution, build both Docker
//    images (with OCI provenance labels), push them to Harbor, gate on Harbor's scan-on-push
//    (fixable Critical), resolve immutable digests, record + archive the release manifest, then
//    invoke the parameterized deploy job and wait for its result.
//
// Bitbucket only mirrors branches + tags to GitHub. A non-SemVer tag publishes/deploys nothing.
//
// Required Jenkins configuration:
//   - Global env: HARBOR_REGISTRY (e.g. harbor.example.com), HARBOR_PROJECT (e.g. event-capture)
//   - Credentials: bitbucket-scm-read (SSH), harbor-ci-robot (username/password)
//   - A downstream job named 'event-capture-deploy' (root Jenkinsfile.deploy)
//   - Agents providing: JDK 21, Node 20+, Docker CLI + daemon, curl, jq

boolean isSemverTag() {
	return env.TAG_NAME?.trim() ==~ /^v\d+\.\d+\.\d+$/
}

boolean isPointerChange() {
	return !env.TAG_NAME?.trim()
}

def initSubmodules() {
	// Relative submodule URLs resolve to git@bitbucket.org:orangethefish/... over the read-only key.
	sshagent(['bitbucket-scm-read']) {
		sh '''
			set -eu
			mkdir -p "$HOME/.ssh"
			chmod 700 "$HOME/.ssh"
			ssh-keyscan -H bitbucket.org >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
			git submodule sync --recursive
			git submodule update --init --recursive
		'''
	}
}

pipeline {
	agent any

	options {
		skipDefaultCheckout(true)
		timestamps()
	}

	environment {
		BACKEND_REPO = 'event-capture-backend'
		FRONTEND_REPO = 'event-capture-frontend'
		BACKEND_MIGRATIONS = 'backend/src/main/resources/db/migration'
	}

	stages {
		stage('Checkout & Submodules') {
			steps {
				deleteDir()
				checkout scm
				script {
					initSubmodules()
					env.ROOT_COMMIT = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
					env.BACKEND_COMMIT = sh(script: 'git -C backend rev-parse HEAD', returnStdout: true).trim()
					env.FRONTEND_COMMIT = sh(script: 'git -C frontend rev-parse HEAD', returnStdout: true).trim()
					env.BACKEND_SOURCE_URL = sh(script: 'git -C backend remote get-url origin', returnStdout: true).trim()
					env.FRONTEND_SOURCE_URL = sh(script: 'git -C frontend remote get-url origin', returnStdout: true).trim()
					echo "root=${env.ROOT_COMMIT} backend=${env.BACKEND_COMMIT} frontend=${env.FRONTEND_COMMIT}"
					if (env.TAG_NAME?.trim() && !isSemverTag()) {
						echo "Tag '${env.TAG_NAME}' is not strict SemVer (vX.Y.Z); no publish/deploy will run."
					}
				}
			}
		}

		stage('Pointer-Change Validation') {
			when { expression { isPointerChange() } }
			steps {
				// The cross-stack journey needs both submodules side by side; it can only run here,
				// not in the standalone frontend job. npm run e2e builds the backend jar via
				// e2e:backend, then Playwright boots it in Redis-free local mode alongside ng serve.
				dir('frontend') {
					sh 'node --version'
					sh 'java -version'
					sh 'npm ci'
					sh 'npx playwright install --with-deps chromium'
					sh 'npm run e2e'
				}
			}
			post {
				always {
					archiveArtifacts allowEmptyArchive: true, artifacts: 'frontend/playwright-report/**, frontend/test-results/**'
				}
			}
		}

		stage('Release: Backend Verification') {
			when { expression { isSemverTag() } }
			steps {
				dir('backend') {
					sh 'java -version'
					sh './gradlew --no-daemon spotlessCheck test phase4ProcessTest openApiCheck bootJar'
					sh 'docker run --rm --entrypoint /bin/promtool -v "$PWD:/workspace" -w /workspace/deploy/prometheus prom/prometheus:v3.5.0 check rules event-capture-alerts.yml'
					sh 'docker run --rm --entrypoint /bin/promtool -v "$PWD:/workspace" -w /workspace/deploy/prometheus prom/prometheus:v3.5.0 test rules event-capture-alerts.test.yml'
					sh 'docker run --rm -v "$PWD:/repo" -w /repo zricethezav/gitleaks:v8.28.0 git --redact --no-banner .'
				}
			}
			post {
				always {
					junit allowEmptyResults: true, testResults: 'backend/build/test-results/**/TEST-*.xml'
				}
			}
		}

		stage('Release: Frontend Verification') {
			when { expression { isSemverTag() } }
			steps {
				dir('frontend') {
					sh 'node --version'
					sh 'npm ci'
					sh 'npm run lint'
					sh 'npm test -- --watch=false --browsers=ChromeHeadless'
					sh 'npm run build -- --configuration production'
				}
			}
		}

		stage('Release: Cross-Stack Journey') {
			when { expression { isSemverTag() } }
			steps {
				dir('frontend') {
					sh 'npx playwright install --with-deps chromium'
					sh 'npm run e2e'
				}
			}
			post {
				always {
					archiveArtifacts allowEmptyArchive: true, artifacts: 'frontend/playwright-report/**, frontend/test-results/**'
				}
			}
		}

		stage('Release: Build, Push & Scan Images') {
			when { expression { isSemverTag() } }
			steps {
				script {
					def registry = env.HARBOR_REGISTRY?.trim()
					def project = env.HARBOR_PROJECT?.trim()
					if (!registry || !project) {
						error('HARBOR_REGISTRY and HARBOR_PROJECT must be configured in Jenkins.')
					}
					def api = "https://${registry}/api/v2.0"
					def backendImage = "${registry}/${project}/event-capture-backend"
					def frontendImage = "${registry}/${project}/event-capture-frontend"
					def tag = env.TAG_NAME.trim()

					// Ensure the artifacts the Dockerfiles copy are present from this pinned tree.
					dir('backend') { sh './gradlew --no-daemon bootJar' }
					dir('frontend') { sh 'npm run build -- --configuration production' }

					sh """
						docker build --pull -f backend/Dockerfile \
							--build-arg SOURCE_COMMIT=${env.BACKEND_COMMIT} \
							--build-arg SOURCE_REPO=${env.BACKEND_SOURCE_URL} \
							--build-arg RELEASE_VERSION=${tag} \
							-t ${backendImage}:${tag} backend
					"""
					sh """
						docker build --pull -f frontend/Dockerfile \
							--build-arg SOURCE_COMMIT=${env.FRONTEND_COMMIT} \
							--build-arg SOURCE_REPO=${env.FRONTEND_SOURCE_URL} \
							--build-arg RELEASE_VERSION=${tag} \
							-t ${frontendImage}:${tag} frontend
					"""

					withCredentials([usernamePassword(credentialsId: 'harbor-ci-robot', usernameVariable: 'HARBOR_USER', passwordVariable: 'HARBOR_PASSWORD')]) {
						withEnv(["HARBOR_REGISTRY=${registry}"]) {
							try {
								sh 'echo "$HARBOR_PASSWORD" | docker login "$HARBOR_REGISTRY" --username "$HARBOR_USER" --password-stdin'
								sh "docker push ${backendImage}:${tag}"
								sh "docker push ${frontendImage}:${tag}"

								// Harbor scan-on-push + poll. Fails on fixable Critical -> release stops before deploy.
								sh "deploy/ci/harbor-scan-gate.sh --api ${api} --project ${project} --repository event-capture-backend --reference ${tag}"
								sh "deploy/ci/harbor-scan-gate.sh --api ${api} --project ${project} --repository event-capture-frontend --reference ${tag}"

								env.BACKEND_DIGEST = sh(script: "deploy/ci/harbor-digest.sh --api ${api} --project ${project} --repository event-capture-backend --reference ${tag}", returnStdout: true).trim()
								env.FRONTEND_DIGEST = sh(script: "deploy/ci/harbor-digest.sh --api ${api} --project ${project} --repository event-capture-frontend --reference ${tag}", returnStdout: true).trim()
								echo "backend digest ${env.BACKEND_DIGEST}, frontend digest ${env.FRONTEND_DIGEST}"
							} finally {
								sh 'docker logout "$HARBOR_REGISTRY" || true'
							}
						}
					}

					env.BACKEND_IMAGE_REF = "${backendImage}@${env.BACKEND_DIGEST}"
					env.FRONTEND_IMAGE_REF = "${frontendImage}@${env.FRONTEND_DIGEST}"
				}
			}
		}

		stage('Release: Manifest') {
			when { expression { isSemverTag() } }
			steps {
				sh """
					deploy/ci/generate-release-manifest.sh \
						--release-tag ${env.TAG_NAME} \
						--root-commit ${env.ROOT_COMMIT} \
						--backend-commit ${env.BACKEND_COMMIT} \
						--frontend-commit ${env.FRONTEND_COMMIT} \
						--backend-image ${env.BACKEND_IMAGE_REF} \
						--frontend-image ${env.FRONTEND_IMAGE_REF} \
						--backend-digest ${env.BACKEND_DIGEST} \
						--frontend-digest ${env.FRONTEND_DIGEST} \
						--migrations-dir ${env.BACKEND_MIGRATIONS} \
						--output release-manifest.json
				"""
				archiveArtifacts artifacts: 'release-manifest.json', fingerprint: true
			}
		}

		stage('Release: Deploy') {
			when { expression { isSemverTag() } }
			steps {
				// Only reached after both pushes and both scan gates succeeded. Wait for the deploy
				// result and propagate failure so a failed deploy fails this tag pipeline.
				build job: 'event-capture-deploy', wait: true, propagate: true, parameters: [
					string(name: 'RELEASE_TAG', value: env.TAG_NAME),
					string(name: 'ROOT_COMMIT', value: env.ROOT_COMMIT),
					string(name: 'BACKEND_IMAGE_DIGEST', value: env.BACKEND_DIGEST),
					string(name: 'FRONTEND_IMAGE_DIGEST', value: env.FRONTEND_DIGEST)
				]
			}
		}
	}
}
