#!/usr/bin/env bash
#
# Copyright 2017 Istio Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################


# Helper functions for extending the mesh with external VMs.

# Script can be sourced in other files or used from tools like ansible.
# Currently the script include helpers for GKE, other providers will be added as
# they are contributed and we test them.

# Environment variables used:
#
# ISTIO_NAMESPACE - control plane namespace, defaults to istio-system, only
# needs to be set for custom deployments
# K8S_CLUSTER - name of the K8S cluster.
# SERVICE_ACCOUNT - what account to provision on the VM. Defaults to default.
# SERVICE_NAMESPACE-  namespace where the service account and service are
# running. Defaults to the current workspace in kube config.
# ISTIO_SECRET_PREFIX - prefix where the istio CA generates secrets for each
# service account. defaults to "istio."
# TODO: read MeshConfig to get the value of control plane auth policy, for now assume mTLS
# CONTROL_PLANE_AUTH_POLICY - control plane auth policy, defaults to "MUTUAL_TLS", only
# needs to be set when "NONE" is desired

# Generate a 'kubedns' Dnsmasq config file using the internal load balancer.
# It will need to be installed on each machine expanding the mesh.
function istioDnsmasq() {
  local NS=${ISTIO_NAMESPACE:-istio-system}
  # Multiple tries, it may take some time until the controllers generate the IPs
  for i in {1..20}
  do
    PILOT_IP=$(kubectl get -n $NS service istio-pilot-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    ISTIO_DNS=$(kubectl get -n kube-system service dns-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    MIXER_IP=$(kubectl get -n $NS service mixer-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    CITADEL_IP=$(kubectl get -n $NS service citadel-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    ZIPKIN_IP=$(kubectl get -n "$NS" service zipkin-ilb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

    if [ "${PILOT_IP}" == "" ] || [  "${ISTIO_DNS}" == "" ] || [ "${MIXER_IP}" == "" ] || [ "${CITADEL_IP}" == "" ] || [ "${ZIPKIN_IP}" == "" ] ; then
      echo "Waiting for ILBs, pilot=$PILOT_IP, MIXER_IP=$MIXER_IP, CITADEL_IP=$CITADEL_IP, DNS=$ISTIO_DNS - kubectl get -n $NS service: $(kubectl get -n $NS service)"
      sleep 30
    else
      break
    fi
  done

  if [ "${PILOT_IP}" == "" ] || [  "${ISTIO_DNS}" == "" ] || [ "${MIXER_IP}" == "" ] || [ "${CITADEL_IP}" == "" ] || [ "${ZIPKIN_IP}" == "" ] ; then
    echo "Failed to create ILBs"
    exit 1
  fi

   #/etc/dnsmasq.d/kubedns
  {
    echo "server=/svc.cluster.local/$ISTIO_DNS"
    echo "address=/istio-policy/$MIXER_IP"
    echo "address=/istio-telemetry/$MIXER_IP"
    echo "address=/istio-pilot/$PILOT_IP"
    echo "address=/istio-citadel/$CITADEL_IP"
    echo "address=/istio-ca/$CITADEL_IP" # Deprecated. For backward compatibility
    echo "address=/zipkin/${ZIPKIN_IP}"
    # Also generate host entries for the istio-system. The generated config will work with both
    # 'cluster-wide' and 'per-namespace'.
    echo "address=/istio-policy.$NS/$MIXER_IP"
    echo "address=/istio-telemetry.$NS/$MIXER_IP"
    echo "address=/istio-pilot.$NS/$PILOT_IP"
    echo "address=/istio-citadel.$NS/$CITADEL_IP"
    echo "address=/istio-ca.$NS/$CITADEL_IP" # Deprecated. For backward compatibility
    echo "address=/zipkin.$NS/${ZIPKIN_IP}"
  } > kubedns

  echo "Generated Dnsmaq config file 'kubedns'. Install it in /etc/dnsmasq.d and restart dnsmasq."
  echo "$0 machineSetup does this for you."
}

# Generate a cluster.env config file.
function istioClusterEnv() {
  local ISTIO_NS=${ISTIO_NAMESPACE:-istio-system}
  local CP_AUTH_POLICY=${CONTROL_PLANE_AUTH_POLICY:-MUTUAL_TLS}

  # TODO: parse it all from $(kubectl config current-context)
  CIDR="10.0.0.0/16"  # To-do: get CIDR from kube context
  echo "ISTIO_SERVICE_CIDR=$CIDR" > cluster.env
  echo "ISTIO_SYSTEM_NAMESPACE=$ISTIO_NS" >> cluster.env
  echo "CONTROL_PLANE_AUTH_POLICY=$CP_AUTH_POLICY" >> cluster.env

  echo "Generated cluster.env, needs to be installed in each VM as /var/lib/istio/envoy/cluster.env"
  echo "the /var/lib/istio/envoy/ directory and files must be readable by 'istio-proxy' user"
  echo "$0 machineSetup does this for you."
}


# Get an istio service account secret, extract it to files to be provisioned on a raw VM
# Params:
# - service account -  defaults to istio.default or SERVICE_ACCOUNT env
# - service namespace - defaults to current namespace.
function istio_provision_certs() {
  local SA=${1:-${SERVICE_ACCOUNT:-default}}
  local NS=${2:-${SERVICE_NAMESPACE:-}}
  local ALL=${3}
  local CERT_NAME=${ISTIO_SECRET_PREFIX:-istio.}${SA}

  if [[ -n "$NS" ]] ; then
    NS="-n $NS"
  fi
  local B64_DECODE=${BASE64_DECODE:-base64 --decode}
  kubectl get $NS secret $CERT_NAME -o jsonpath='{.data.root-cert\.pem}' | $B64_DECODE   > root-cert.pem
  echo "Generated root-cert.pem. It should be installed on /etc/certs"
  if [ "$ALL" == "all" ] ; then
    kubectl get $NS secret $CERT_NAME -o jsonpath='{.data.cert-chain\.pem}' | $B64_DECODE  > cert-chain.pem
    kubectl get $NS secret $CERT_NAME -o jsonpath='{.data.key\.pem}' | $B64_DECODE   > key.pem
    echo "Generated cert-chain.pem and key.pem. It should be installed on /etc/certs"
  fi

  echo "the directory and files must be owned by 'istio-proxy' user"
  echo "$0 machineSetup does this for you."
}



# Install required files on a VM and run the setup script.
# This is an example to help integrating the steps into the admin automation tools.
#
# Must be run for each VM added to the cluster
# Params:
# - name of the VM - used to copy files over.
# - istio version - used for setup istio on the vm.
# - optional service account to be provisioned (defaults to istio.default)
# - optional namespace of the service account and VM services, defaults to SERVICE_NAMESPACE env
# or kube config.
#
# Expected to be run from the release directory (ie istio-0.2.8/ or istio/)
function istioBootstrapVM() {
  local DESTINATION=${1}
  local VERSION=${2:-${ISTIO_VERSION}}
  local SA=${3:-${SERVICE_ACCOUNT:-default}}
  local NS=${4:-${SERVICE_NAMESPACE:-}}
  
  if [[ -n "$VERSION" ]]; then
    # To-do: replace hard-coded deb URL
    echo "export PILOT_DEBIAN_URL=https://storage.googleapis.com/istio-release/releases/$VERSION/deb" > istio.VERSION
  else
    echo "Must specify istio version either in parameter or environment variable: ISTIO_VERSION"
    echo "Exiting..."
    return 1
  fi

  DEFAULT_SCRIPT="./meshexpansion/setupIstioVM.sh"
  SETUP_ISTIO_VM_SCRIPT=${SETUP_ISTIO_VM_SCRIPT:-${DEFAULT_SCRIPT}}
  echo "Making certs for service account $SA (namespace $NS)"
  istio_provision_certs $SA $NS "all"

  local DIRECTORY="~/.meshExpansion"
  istioRun $DESTINATION "mkdir -p $DIRECTORY"

  for i in {1..10}; do
    # Copy deb, helper and config files
    istioCopy $DESTINATION \
      $DIRECTORY \
      kubedns \
      *.pem \
      cluster.env \
      istio.VERSION \
      ${SETUP_ISTIO_VM_SCRIPT}

    if [[ $? -ne 0 ]]; then
      echo "scp failed, retry in 10 sec"
      sleep 10
    else
      echo "scp succeeded"
      break
    fi
  done

  # Run the setup script.
  istioRun $DESTINATION "cd $DIRECTORY && sudo bash -c -x $DIRECTORY/setupIstioVM.sh"
}


# Helper functions for the main script

# Copy files to the VM.
# - VM name - required, destination where files will be copied
# - list of files and directories to be copied
function istioCopy() {
  # TODO: based on some env variable, use different commands for other clusters or for testing with
  # bare-metal machines.
  local NAME=$1
  shift
  local DIRECTORY=$1
  shift
  local FILES=$*

  ${ISTIO_CP:-scp -r} $FILES ${NAME}:${DIRECTORY}
}

# Run a command in a VM.
# - VM name
# - command to run, as one parameter.
function istioRun() {
  local NAME=$1
  local CMD=$2
  
  ${ISTIO_RUN:-ssh} $NAME $CMD
}

if [[ ${1:-} == "generateClusterEnv" ]] ; then
  istioClusterEnv
elif [[ ${1:-} == "generateDnsmasq" ]] ; then
  istioDnsmasq
elif [[ ${1:-} == "machineCerts" ]] ; then
  shift
  istio_provision_certs $1 $2 $3
elif [[ ${1:-} == "machineSetup" ]] ; then
  shift
  istioBootstrapVM $1 $2 $3 $4
else
  echo "$0 generateClusterEnv: Generate cluster range config files (one time)"
  echo "$0 generateDnsmasq: Generate dnsmasq config files (one time)"
  echo "$0 machineCerts SERVICE_ACCOUNT NAMESPACE: Generate bootstrap machine certs. Uses 'default' account if no parameters. NAMESPACE specified in which namespace services are depolyed (one time per host)"
  echo "$0 machineSetup HOST ISTIO_VERSION SERVICE_ACCOUNT NAMESPACE: Copy files to HOST, and run the setup script for specified ISTIO_VERSION. SERVICE_ACCOUNT and NAMESPACE are used for generating bootstrap machine certs (one time per host)"
fi
