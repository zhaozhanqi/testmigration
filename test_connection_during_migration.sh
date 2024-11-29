#!/bin/bash


function pause_migration() {
    cat <<EOF | oc create -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  creationTimestamp: null
  name: pause-mco-pdb
  namespace: pause-mco-temporary
spec:
  maxUnavailable: 0
  selector:
      matchLabels:
          name: pause-mco
status: {}
EOF
}

oc create namespace z4 && oc label namespace z4 team=qe pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged security.openshift.io/scc.podSecurityLabelSync=false --overwrite
oc create namespace z3 && oc label namespace z3 pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged security.openshift.io/scc.podSecurityLabelSync=false --overwrite

for namespace in z3 z4
do 
echo 'apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: hello
  namespace: "'$namespace'"
  labels:
    name: test
spec:
  selector:
    matchLabels:
      name: test
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: test
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
      tolerations:
      - operator: Exists
      containers:
      - name: hello-pod
        image: quay.io/openshifttest/nginx-alpine@sha256:04f316442d48ba60e3ea0b5a67eb89b0b667abf1c198a3d0056ca748736336a0' | oc create -f  -
done


####Create mco 
cat <<EOF1 | oc create -f -
apiVersion: v1
kind: List
items:
- apiVersion: v1
  kind: Namespace
  metadata:
    labels:
      kubernetes.io/metadata.name: pause-mco-temporary
    name: pause-mco-temporary
  spec: {}
  status: {}
- apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: pause-mco-temporary-hostnetwork
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: system:openshift:scc:hostnetwork
  subjects:
    - kind: ServiceAccount
      name: default
      namespace: pause-mco-temporary
- apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: pause-mco
    namespace: pause-mco-temporary
    labels:
      k8s-app: pause-mco
  spec:
    replicas: 6
    selector:
      matchLabels:
        name: pause-mco
    template:
      metadata:
        labels:
          name: pause-mco
      spec:
        hostNetwork: true
        tolerations:
          - operator: Exists
        containers:
          - name: pause-mco
            command:
              - sleep
            args:
              - infinity
            image: registry.redhat.io/rhel9/support-tools:latest
        affinity:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector:
                  matchLabels:
                    name: pause-mco
                topologyKey: kubernetes.io/hostname
EOF1

timeout 60s bash <<EOT
until
  oc wait pod --for='condition=Ready=True' -n z3 --all
  oc wait pod --for='condition=Ready=True' -n z4 --all
  oc wait pod --for='condition=Ready=True' -n pause-mco-temporary --all
do
  sleep 5
  echo " pods not ready"
done
EOT

if [ $? -eq 124 ]; then
        echo "pod in z3/z4/pause-mco-temporary not ready"
        exit 1
fi

###create networkpolicy to make pods from z4 can be accessed pods in z3
cat <<EOF | oc create -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: z3
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: allow-all-ingress
  namespace: z3
spec:
  ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            team: qe
        podSelector:
          matchLabels:
            name: test
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-openshift-ingress
  namespace: z3
spec:
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          policy-group.network.openshift.io/ingress: ""
  podSelector: {}
  policyTypes:
  - Ingress
EOF


###do live migration
oc patch Network.config.openshift.io cluster --type='merge' --patch '{"metadata":{"annotations":{"network.openshift.io/network-type-migration":""}},"spec":{"networkType":"OVNKubernetes"}}'

timeout 60m bash <<EOT
until
  oc describe pod -n z3 | grep "name.*ovn-kubernetes"
do
  sleep 30
  echo "waiting one node pods begins to use ovn-k cni"
done
EOT

if [ $? -eq 124 ]; then
        echo "no pods in z3 using ovn-k"
        exit 2
fi

<<com
while true;
do
 z4_ovn=$(oc describe pod -n z4 | grep "name.*ovn-kubernetes")
 z3_ovn=$(oc describe pod -n z3| grep "name.*ovn-kubernetes")
 #z4_ovn=$(oc describe pod -n z4 | grep "name.*openshift-sdn")
 #z3_ovn=$(oc describe pod -n z3| grep "name.*openshift-sdn")

 if [ -z "$z4_ovn" ] && [ -z "$z3_ovn" ];then
	 echo "waiting one node pods begins to use ovn-k cni"
	 sleep 30
 else
	 break
 fi
done
com

#####now stop migration to test the connection between sdn cni and ovn-k cni in different node
pause_migration
sleep 60 

timeout 160s bash <<EOT
until
  oc wait pod --for='condition=Ready=True' -n z3 --all
  oc wait pod --for='condition=Ready=True' -n z4 --all
do
  sleep 5
  echo "pods not ready"
done
EOT

pod_name_z4=$(oc get pods -n z4 -o jsonpath='{.items[*].metadata.name}')
pod_ip_z3=$(oc get pods -n z3 -o jsonpath='{.items[*].status.podIP}')

connection_pod2pod=0
for pod_i in $pod_name_z4
do
	echo $pod_i;
	for p_ip in $pod_ip_z3
	do
		echo oc exec -n z4 $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
		oc exec -n z4 $pod_i -- curl --connect-timeout 5 network-check-target.openshift-network-diagnostics.svc 2>/dev/null && oc exec -n z4 $pod_i -- curl --connect-timeout 5 ifconfig.me 2>/dev/null && echo && oc exec -n z4 $pod_i -- curl --connect-timeout 5${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
		if [ $? != 0 ]; then
			echo "########################################"
			echo oc exec -n z4 $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
			echo "########################################"
			echo oc describe pod $pod_i -n z4
			oc describe pod $pod_i -n z4
                        podname_z3=$(oc get pod -n z3 -o wide --no-headers | grep ${p_ip} | cut -f1 -d" ")
			echo "########################################"
			echo oc describe pod $podname_z3 -n z3
			oc describe pod $podname_z3 -n z3
			connection_pod2pod=1
		fi
	done
done

connection_hostnetwork2pod=0
pod_name_multus=$(oc get pods -n openshift-multus -l app=multus -o jsonpath='{.items[*].metadata.name}')
pod_ip_z3=$(oc get pods -n z3 -o jsonpath='{.items[*].status.podIP}')

for pod_i in $pod_name_multus
do
        echo $pod_i;
        for p_ip in $pod_ip_z3
        do
		echo oc exec -n openshift-multus $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
                oc exec -n openshift-multus $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
                if [ $? != 0 ]; then
                        echo "########################################"
                        echo oc exec -n openshift-multus $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
                        echo "########################################"
                        echo oc describe pod $pod_i -n openshift-multus
                        oc describe pod $pod_i -n openshift-multus
                        podname_z3=$(oc get pod -n z3 -o wide --no-headers | grep ${p_ip} | cut -f1 -d" ")
                        echo "########################################"
                        echo oc describe pod $podname_z3 -n z3
                        oc describe pod $podname_z3 -n z3
			connection_hostnetwork2pod=1
                fi
        done
done

if [[ $connection_hostnetwork2pod == 0 && $connection_pod2pod == 0 ]]; then
	###unset pause migration,continue migration
	echo "all connection testing pass with different cni"
	oc delete PodDisruptionBudget pause-mco-pdb -n pause-mco-temporary
else
	#exit for debugging
	echo "connection_hostnetwork2pod:$connection_hostnetwork2pod"
	echo "connection_pod2pod:$connection_pod2pod"
	echo " pod2pod or hostnetwork2pod testing failed, exit"
	exit 2
fi


<<dom
#Delete pods z4 to make them recreated
oc delete pod -n z4 --all 
sleep 10

>error.log
while true;
do
pod_name=$(oc get pod -n z4 -o wide -l name=test --no-headers |grep Running | cut -f1 -d" ")

#pod_ip=$(oc get pod -n z3 -o wide -l name=test --no-headers | grep Running | awk '{print $6}')
pod_host=$(oc get pod -n z3 -o wide -l name=test --no-headers | awk '{print $7}')

for pod_i in $pod_name
do
  echo $pod_i;
  pod_ip=$(oc get pod -n z3 -o wide -l name=test --no-headers | grep Running | awk '{print $6}')
  for p_ip in $pod_ip
  do
	  pod_z4_ready=$(oc get pod $pod_i -n z4 -o=jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
	  pod_z3=$(oc get pod -n z3 -o wide --no-headers | grep ${p_ip} | cut -f1 -d" ")
	  pod_z3_ready=$(oc get pod $pod_z3 -n z3 -o=jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

	  pod_z4_plugin=$(oc describe pod -n z4 $pod_i| grep "name.*:.*" | awk -F'"name": "|"' '{print $2}')
	  pod_z3_plugin=$(oc describe pod -n z3 $pod_z3| grep "name.*:.*" | awk -F'"name": "|"' '{print $2}')

	  if [[ ${pod_z4_ready} != "True" || ${pod_z3_ready} != "True" || $pod_z4_plugin == $pod_z3_plugin ]]; then
		  continue
	  else
	    #echo oc exec -n z3 $pod_i -- curl --connect-timeout 10 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
	    oc exec -n z4 $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null
	    if [ $? != 0 ]; then
	      date ;
	      current_time=$(date '+%Y-%m-%d %H:%M:%S')
	      echo $current_time >> error.log
	      oc get pod -n z3 -o wide >> error.log
	      oc get pod -n z4 -o wide >> error.log
	      echo oc exec -n z4 $pod_i -- curl --connect-timeout 3 ${p_ip}:8080 https://${p_ip}:8443 -k 2>/dev/null >>error.log
	      echo -e "\033[41;37m pod ${pod_i} can not communicate with ${p_ip} with 8080 or 8443 port \033[0m" >>error.log
	      echo oc describe pod $pod_i -n z4 >> error.log
	      echo "###############################################" >>error.log
	      oc describe pod $pod_i -n z4 >> error.log
	      podname_z3=$(oc get pod -n z3 -o wide --no-headers | grep ${p_ip} | cut -f1 -d" ")
	      echo "###############################################" >>error.log
	      echo oc describe pod $podname_z3 -n z3 >> error.log
	      oc describe pod $podname_z3 -n z3 >> error.log
	      # stop migration
	      oc create -f pause-mco-pdb.yaml
	      #exit 2
	    fi
	  fi
    #echo oc exec -n z3 $pod_i -- curl --connect-timeout 5 https://${p_ip}:8443 -k 2>/dev/null
    #oc exec -n z3 $pod_i -- curl --connect-timeout 5 https://${p_ip}:8443 -k 2>/dev/null
    #if [ $? != 0 ]; then
    #  echo pod ${pod_i} can not communicate with ${p_ip} with 8443 port
    #  exit 2
    #fi
  done
done
done
dom
