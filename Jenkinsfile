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
//   - Credentials: harbor-credentials (username/password)
//   - A downstream job named 'event-capture-deploy' (root Jenkinsfile.deploy)
//   - Agents providing: JDK 21, Node 20+, Docker CLI + daemon, curl, jq

boolean isSemverTag() {
	return env.TAG_NAME?.trim() ==~ /^v\d+\.\d+\.\d+$/
}

boolean isPointerChange() {
	return !env.TAG_NAME?.trim()
}

def initSubmodules() {
	sh '''
		set -eu
		git submodule sync --recursive
		git submodule update --init --recursive
		git submodule status --recursive
	'''
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
		HARBOR_REGISTRY = credentials('registry-url')
		HARBOR_PROJECT = 'duyhoa2210'
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
					sh 'npx playwright install chromium'
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
					sh 'bash ci/karma-ci.sh --watch=false --browsers=ChromeHeadlessNoSandbox'
					sh 'npm run build -- --configuration production'
				}
			}
		}

		stage('Release: Cross-Stack Journey') {
			when { expression { isSemverTag() } }
			steps {
				dir('frontend') {
					sh 'npx playwright install chromium'
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
					def backendImageName = "${registry}/${project}/event-capture-backend"
					def frontendImageName = "${registry}/${project}/event-capture-frontend"
					def tag = env.TAG_NAME.trim()

					// Ensure the artifacts the Dockerfiles copy are present from this pinned tree.
					dir('backend') { sh './gradlew --no-daemon bootJar' }
					dir('frontend') { sh 'npm run build -- --configuration production' }

					docker.withRegistry(env.HARBOR_REGISTRY?.trim(), 'harbor-credentials') {
						// Build and push backend image
						def backendImage = docker.build(
							"${backendImageName}:${tag}",
							"--pull " +
							"--build-arg SOURCE_COMMIT=${env.BACKEND_COMMIT} " +
							"--build-arg SOURCE_REPO=${env.BACKEND_SOURCE_URL} " +
							"--build-arg RELEASE_VERSION=${tag} " +
							"-f backend/Dockerfile backend"
						)
						backendImage.push()

						// Build and push frontend image
						def frontendImage = docker.build(
							"${frontendImageName}:${tag}",
							"--pull " +
							"--build-arg SOURCE_COMMIT=${env.FRONTEND_COMMIT} " +
							"--build-arg SOURCE_REPO=${env.FRONTEND_SOURCE_URL} " +
							"--build-arg RELEASE_VERSION=${tag} " +
							"-f frontend/Dockerfile frontend"
						)
						frontendImage.push()
					}

					// Harbor API calls need credentials as env vars (docker.withRegistry only sets Docker CLI auth)
					withCredentials([usernamePassword(credentialsId: 'harbor-credentials', usernameVariable: 'HARBOR_USER', passwordVariable: 'HARBOR_PASSWORD')]) {
						// Harbor scan-on-push + poll. Fails on fixable Critical -> release stops before deploy.
						sh "deploy/ci/harbor-scan-gate.sh --api ${api} --project ${project} --repository event-capture-backend --reference ${tag}"
						sh "deploy/ci/harbor-scan-gate.sh --api ${api} --project ${project} --repository event-capture-frontend --reference ${tag}"

						env.BACKEND_DIGEST = sh(script: "deploy/ci/harbor-digest.sh --api ${api} --project ${project} --repository event-capture-backend --reference ${tag}", returnStdout: true).trim()
						env.FRONTEND_DIGEST = sh(script: "deploy/ci/harbor-digest.sh --api ${api} --project ${project} --repository event-capture-frontend --reference ${tag}", returnStdout: true).trim()
						echo "backend digest ${env.BACKEND_DIGEST}, frontend digest ${env.FRONTEND_DIGEST}"
					}

					env.BACKEND_IMAGE_REF = "${backendImageName}@${env.BACKEND_DIGEST}"
					env.FRONTEND_IMAGE_REF = "${frontendImageName}@${env.FRONTEND_DIGEST}"
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
				build job: 'Event Capture/EC-deploy', wait: true, propagate: true, parameters: [
					string(name: 'RELEASE_TAG', value: env.TAG_NAME),
					string(name: 'ROOT_COMMIT', value: env.ROOT_COMMIT),
					string(name: 'BACKEND_IMAGE_DIGEST', value: env.BACKEND_DIGEST),
					string(name: 'FRONTEND_IMAGE_DIGEST', value: env.FRONTEND_DIGEST)
				]
			}
		}
	}
}
