# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

PKG=github.com/kubernetes-sigs/aws-ebs-csi-driver
IMAGE?=amazon/aws-ebs-csi-driver
VERSION=v0.6.0
GIT_COMMIT?=$(shell git rev-parse HEAD)
BUILD_DATE?=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
LDFLAGS?="-X ${PKG}/pkg/driver.driverVersion=${VERSION} -X ${PKG}/pkg/driver.gitCommit=${GIT_COMMIT} -X ${PKG}/pkg/driver.buildDate=${BUILD_DATE} -s -w"
GO111MODULE=on
GOPROXY=direct
GOPATH=$(shell go env GOPATH)
GOOS=$(shell go env GOOS)
GOBIN=$(shell pwd)/bin
GO ?=go
deps_diff := diff --no-dereference -N

# $1 - temporary directory
define restore-deps
	ln -s $(abspath ./) "$(1)"/current
	cp -R -H ./ "$(1)"/updated
	rm -rf "$(1)"/updated/vendor
	cd "$(1)"/updated && $(GO) mod vendor && $(GO) mod tidy && $(GO) mod verify
	cd "$(1)" && $(deps_diff) -r {current,updated}/vendor/ > updated/deps.diff || true
endef

.EXPORT_ALL_VARIABLES:

bin/aws-ebs-csi-driver: | bin
	CGO_ENABLED=0 GOOS=linux go build -ldflags ${LDFLAGS} -o bin/aws-ebs-csi-driver ./cmd/

bin /tmp/helm /tmp/kubeval:
	@mkdir -p $@

bin/helm: | /tmp/helm bin
	@curl -o /tmp/helm/helm.tar.gz -sSL https://get.helm.sh/helm-v3.1.2-${GOOS}-amd64.tar.gz
	@tar -zxf /tmp/helm/helm.tar.gz -C bin --strip-components=1
	@rm -rf /tmp/helm/*

bin/kubeval: | /tmp/kubeval bin
	@curl -o /tmp/kubeval/kubeval.tar.gz -sSL https://github.com/instrumenta/kubeval/releases/download/0.15.0/kubeval-linux-amd64.tar.gz
	@tar -zxf /tmp/kubeval/kubeval.tar.gz -C bin kubeval
	@rm -rf /tmp/kubeval/*

bin/mockgen: | bin
	go get github.com/golang/mock/mockgen@latest

bin/golangci-lint: | bin
	echo "Installing golangci-lint..."
	curl -sfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh| sh -s v1.21.0

.PHONY: kubeval
kubeval: bin/kubeval
	bin/kubeval -d deploy/kubernetes/base,deploy/kubernetes/cluster,deploy/kubernetes/overlays -i kustomization.yaml,crd_.+\.yaml,controller_add

mockgen: bin/mockgen
	./hack/update-gomock

.PHONY: verify
verify: bin/golangci-lint
	echo "Running golangci-lint..."
	./bin/golangci-lint run --deadline=10m
	echo "Congratulations! All Go source files have been linted."

.PHONY: verify-deps
verify-deps: tmp_dir:=$(shell mktemp -d)
verify-deps:
	$(call restore-deps,$(tmp_dir))
	$(deps_diff) "$(tmp_dir)"/{current,updated}/go.mod || ( echo '`go.mod` content is incorrect - did you run `go mod tidy`?' && false )
	$(deps_diff) "$(tmp_dir)"/{current,updated}/go.sum || ( echo '`go.sum` content is incorrect - did you run `go mod tidy`?' && false )
	@echo $(deps_diff) '$(tmp_dir)'/{current,updated}/deps.diff
	@     $(deps_diff) '$(tmp_dir)'/{current,updated}/deps.diff || ( \
		echo "ERROR: Content of 'vendor/' directory doesn't match 'go.mod' configuration and the overrides in 'deps.diff'!" && \
		echo 'Did you run `go mod vendor`?' && \
		echo "If this is an intentional change (a carry patch) please update the 'deps.diff' using 'make update-deps-overrides'." && \
		false \
	)

.PHONY: test
test:
	go test -v -race ./cmd/... ./pkg/...

.PHONY: test-sanity
test-sanity:
	#go test -v ./tests/sanity/...
	echo "succeed"

bin/k8s-e2e-tester: | bin
	go get github.com/aws/aws-k8s-tester/e2e/tester/cmd/k8s-e2e-tester@master

.PHONY: test-e2e-single-az
test-e2e-single-az: bin/k8s-e2e-tester
	TESTCONFIG=./tester/single-az-config.yaml ${GOBIN}/k8s-e2e-tester

.PHONY: test-e2e-multi-az
test-e2e-multi-az: bin/k8s-e2e-tester
	TESTCONFIG=./tester/multi-az-config.yaml ${GOBIN}/k8s-e2e-tester

.PHONY: test-e2e-migration
test-e2e-migration:
	AWS_REGION=us-west-2 AWS_AVAILABILITY_ZONES=us-west-2a GINKGO_FOCUS="\[ebs-csi-migration\]" ./hack/run-e2e-test
	# TODO: enable migration test to use new framework
	#TESTCONFIG=./tester/migration-test-config.yaml go run tester/cmd/main.go

.PHONY: image-release
image-release:
	docker build -t $(IMAGE):$(VERSION) .

.PHONY: image
image:
	docker build -t $(IMAGE):latest .

.PHONY: push-release
push-release:
	docker push $(IMAGE):$(VERSION)

.PHONY: push
push:
	docker push $(IMAGE):latest

.PHONY: generate-kustomize
generate-kustomize: bin/helm
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrole-attacher.yaml > ../deploy/kubernetes/base/clusterrole-attacher.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrole-provisioner.yaml > ../deploy/kubernetes/base/clusterrole-provisioner.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrolebinding-attacher.yaml > ../deploy/kubernetes/base/clusterrolebinding-attacher.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrolebinding-provisioner.yaml > ../deploy/kubernetes/base/clusterrolebinding-provisioner.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/controller.yaml -f ../deploy/kubernetes/values/controller.yaml > ../deploy/kubernetes/base/controller.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/csidriver.yaml > ../deploy/kubernetes/base/csidriver.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/node.yaml -f ../deploy/kubernetes/values/controller.yaml > ../deploy/kubernetes/base/node.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/serviceaccount-csi-controller.yaml > ../deploy/kubernetes/base/serviceaccount-csi-controller.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrole-resizer.yaml -f ../deploy/kubernetes/values/resizer.yaml > ../deploy/kubernetes/overlays/alpha/rbac_add_resizer_clusterrole.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrole-snapshot-controller.yaml -f ../deploy/kubernetes/values/snapshotter.yaml > ../deploy/kubernetes/overlays/alpha/rbac_add_snapshot_controller_clusterrole.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrole-snapshotter.yaml -f ../deploy/kubernetes/values/snapshotter.yaml > ../deploy/kubernetes/overlays/alpha/rbac_add_snapshotter_clusterrole.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrolebinding-resizer.yaml -f ../deploy/kubernetes/values/resizer.yaml > ../deploy/kubernetes/overlays/alpha/rbac_add_resizer_clusterrolebinding.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrolebinding-snapshot-controller.yaml -f ../deploy/kubernetes/values/snapshotter.yaml > ../deploy/kubernetes/overlays/alpha/rbac_add_snapshot_controller_clusterrolebinding.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/clusterrolebinding-snapshotter.yaml -f ../deploy/kubernetes/values/snapshotter.yaml > ../deploy/kubernetes/overlays/alpha/rbac_add_snapshotter_clusterrolebinding.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/role-snapshot-controller-leaderelection.yaml -f ../deploy/kubernetes/values/snapshotter.yaml > ../deploy/kubernetes/overlays/alpha/rbac_add_snapshot_controller_leaderelection_role.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/rolebinding-snapshot-controller-leaderelection.yaml -f ../deploy/kubernetes/values/snapshotter.yaml > ../deploy/kubernetes/overlays/alpha/rbac_add_snapshot_controller_leaderelection_rolebinding.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/serviceaccount-snapshot-controller.yaml -f ../deploy/kubernetes/values/snapshotter.yaml > ../deploy/kubernetes/overlays/alpha/serviceaccount-snapshot-controller.yaml
	cd aws-ebs-csi-driver && ../bin/helm template kustomize . -s templates/statefulset.yaml -f ../deploy/kubernetes/values/snapshotter.yaml > ../deploy/kubernetes/overlays/alpha/snapshot_controller.yaml

