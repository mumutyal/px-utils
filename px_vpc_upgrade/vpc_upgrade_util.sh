#!/bin/bash

# Usage: vpc_upgrade_util.sh  clustername  
#
shopt -s expand_aliases
alias ic="ibmcloud"

[[ -z "$1" ]] && { echo "Cluster name is empty, specify a cluster name."; exit; }
#vol_ids=()
#for ((argindex=2,index=0; argindex<=$#; argindex++,index++)); do
#  vol_ids[index]=${!argindex}
#done

IFS='/' read -r -a CLUSTER_POOL <<< "$1"
CLUSTER=${CLUSTER_POOL[0]}
COUNT=${2:-1}
PROFILE=${3:-general-purpose}
SIZE=${4:-100}
WORKER_POOL=""
WORKER_POOL_NAME="all"
CLUSTER_CHECK=$(kubectl -n kube-system get cm cluster-info -o jsonpath='{.data.cluster-config\.json}' | jq -r '.name')
echo "${CLUSTER_CHECK}"
[[ -z "$CLUSTER_CHECK" ]] && { echo "Unable to determine cluster name, Either the cluser does not exist or kube config is not set."; exit; }
[[ ${#CLUSTER_POOL[@]} -gt 1 ]] && { WORKER_POOL="--worker-pool ${CLUSTER_POOL[1]}"; WORKER_POOL_NAME="${CLUSTER_POOL[1]}";}

echo "Gathering information for cluster ${CLUSTER} ..."
VPC_ID=$(ic cs cluster get --cluster $CLUSTER --json | jq -r '.vpcs[0]')
WORKER_IDS=$(ic cs workers --cluster $CLUSTER $WORKER_POOL --json | jq -r '.[] | .id')
CLUSTER_ID=$(ic cs cluster get --cluster ${CLUSTER} --json | jq -r '.id')
JOB_COMMAND="/bin/systemctl restart  portworx;sleep 60"

waitforthenode () {

DESIRED=1
ALLREADY=0
UPGRADE_STARTED=0
LIMIT=20
SLEEP_TIME=60
LONG_SLEEP_TIME=120

   ALLREADY=0
   repeat=0

   oldifs="$IFS"
   IFS=$'\n'
   workers=($(ic cs workers --cluster $CLUSTER | grep $CLUSTER_ID)) 
   worker_cnt=${#workers[@]}
   while [ $repeat -lt $LIMIT ] && [ $UPGRADE_STARTED -ne $DESIRED ]; do
     workers=($(ic cs workers --cluster $CLUSTER | grep $CLUSTER_ID)) 
     for worker in "${workers[@]}"; do
         worker_state=$(echo $worker | awk '{print $5}')
         if [[ $worker_state != "Ready" ]]; then
             echo "The upgrade started"
             UPGRADE_STARTED=1             
             break
        else
         echo "All workers are in ready state .... Upgrade is not yet started .. sleeping"
     fi
     done
         sleep $SLEEP_TIME
         repeat=$(( $repeat + 1 ))
         if [ $repeat == $LIMIT ]; then
           echo "Upgrade is not triggered from catalog ..Exiting ... Run the script again and trigger the upgrade from Dashboard"
           exit 1
         fi
   done
   sleep $LONG_SLEEP_TIME
   repeat=0
  ## Here wait for the 1 hour as the worker proviison takes long time
   LIMIT=90
   #oldifs="$IFS"
   #IFS=$'\n'
   #workers=($(ic cs workers --cluster $CLUSTER | grep $CLUSTER_ID)) 
   #IFS="$oldifs"
   while [ $repeat -lt $LIMIT ] && [ $ALLREADY -ne $DESIRED ]; do
     workers=($(ic cs workers --cluster $CLUSTER | grep $CLUSTER_ID)) 
      worker_rdy_cnt=0
    for worker in "${workers[@]}"; do
      worker_state=$(echo $worker | awk '{print $5}')
      if [[ $worker_state == "Ready" ]]; then
         worker_rdy_cnt=$(( $worker_rdy_cnt + 1 ))
         if  [ $worker_rdy_cnt -eq $worker_cnt ]; then
            echo "Upgrade is done and All worker nodes are in ready state...."
            ALLREADY=1
            break
         fi
       else
         echo "One or more workers are not in ready state  Total no of workers :$worker_cnt.. Avialble workers :$worker_rdy_cnt.... waiting for new worker provision to complete"
         sleep $SLEEP_TIME
         repeat=$(( $repeat + 1 ))
      fi
     done 
   done
    IFS="$oldifs"
}

restartPortworxService () {
   NAMESPACE="ibm-system"
   WORKER_IP=$1
   echo " Restarting the Portworx Service on worker node $WORKER_IP"
   JOB_NAME=$(LC_CTYPE=C cat /dev/urandom | base64 | tr -dc a-z0-9 | fold -w 32 | head -n 1)
   (cat << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: runon-shell
spec:
  template:
    spec:
      tolerations:
        - operator: "Exists"
      nodeSelector:
        kubernetes.io/hostname:  $WORKER_IP
      containers:
        - name: runon
          image: "alpine:3.10"
          command:
            - sh
            - -c
            - nsenter -t 1 -m -u -i -n -p  -- bash -c "${JOB_COMMAND}"
          securityContext:
            privileged: true
      hostPID: true
      restartPolicy: Never
EOF
) | if ! kubectl create -f - 2>&1 > /dev/null; then

  echo "unable to Restart the Portworx service on worker node, bailing out"
  exit 1
fi


# get the uid

ID=$(kubectl get job ${JOB_NAME} -n ${NAMESPACE} -o 'jsonpath={.metadata.uid}')
if [ -z "${ID}" ]; then
  echo "ERR unable to get job id"
  exit 1
fi
}







waitforportworxpods() {
DESIRED=$(kubectl get ds/portworx -n kube-system -o json | jq .status.desiredNumberScheduled)
RUNNING=0
LIMIT=20
SLEEP_TIME=30
i=0

while [ $i -lt $LIMIT ] && [ $DESIRED -ne $RUNNING ]; do 
    RUNNING=$(kubectl get pods -n kube-system -l name=portworx --field-selector status.phase=Running -o json | jq '.items | length') 
    if [ $DESIRED -eq $RUNNING ]; then 
        echo "(Attempt $i of $LIMIT) Portworx pods: Desired $DESIRED, Running $RUNNING"
    else 
        echo "(Attempt $i of $LIMIT) Portworx pods: Desired $DESIRED, Running $RUNNING, sleeping $SLEEP_TIME"
        sleep $SLEEP_TIME
    fi 
    i=$(( $i + 1 ))
done
echo "All the pods moved to running state" 
}


#####Before upgrade bring the volume ids using the worker id
volindex=0
for id in ${WORKER_IDS}
do
   IFS='-' read -r -a WORKER_VALS <<< "$id"
   zone=$(ic cs worker get --worker $id --cluster $CLUSTER --json | jq -r .location)
   volid_perworker=$(ic is vols --json | jq -r --arg WORKER_NAME "$id" '.[]|select(.volume_attachments[] .instance.name==$WORKER_NAME) | .id')
   echo "volid :${volid_perworker[*]} is attched to the worker :${id}"
   vol_ids[volindex]=${volid_perworker[@]}
   ((volindex++))
done

#### Wait for the Portowrx pods to become up and availble

waitforthenode
waitforportworxpods

##Get all the volume ids in the cluster
index="0"
WORKER_IDS=$(ic cs workers --cluster $CLUSTER $WORKER_POOL --json | jq -r '.[] | .id')
for vol_id in ${vol_ids}
do
  volume_attch_check=$(ic is vol ${vol_id} --json | jq -r '.volume_attachments[] .instance | .name')
  if [ -z "$volume_attch_check" ]; then
     echo "Volume is not attched to any node"
      for id in ${WORKER_IDS}
      do
          IFS='-' read -r -a WORKER_VALS <<< "$id"
          zone=$(ic cs worker get --worker $id --cluster $CLUSTER --json | jq -r .location) 
          check_worker_attch=$(ic is vols --json | jq -r --arg WORKER_NAME "$id" '.[]|select(.volume_attachments[] .instance.name==$WORKER_NAME) | .id')
          if [ -z "$check_worker_attch" ]; then
             echo "Worker node is not attached to any Volume $id"
             echo "Attaching the volume ....cluster $CLUSTER_ID worker ${id} volid ${vol_id}"
             ic cs storage attachment create --cluster ${CLUSTER_ID} --worker ${id} --volume ${vol_id}
             sleep 30
             restartPortworxService $id
             break
           else
             echo "Worker have volume attchements $id"
          fi
        done
    else
      echo "Volume is already attched"
    fi
done
         

