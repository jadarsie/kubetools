#!/bin/bash -e

FILE_NAME=$0

SCRIPT_FOLDER="$(dirname $FILE_NAME)"
GIT_REPROSITORY="${GIT_REPROSITORY:-msazurestackworkloads/kubetools}"
GIT_BRANCH="${GIT_BRANCH:-master}"
COMMON_SCRIPT_FILENAME="common.sh"

# Download common script file.
FILE=/etc/resolv.conf
if [ ! -f $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME ]; then
    curl -o $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME \
    https://raw.githubusercontent.com/$GIT_REPROSITORY/$GIT_BRANCH/applications/common/$COMMON_SCRIPT_FILENAME
    if [ ! -f $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME ]; then
        log_level -e "File($COMMON_SCRIPT_FILENAME) failed to download."
        exit 1
    fi
fi

source $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME
###########################################################################################################
# The function will read parameters and populate below global variables.
# IDENTITY_FILE, MASTER_IP, OUTPUT_SUMMARYFILE, USER_NAME
parse_commandline_arguments $@

log_level -i "------------------------------------------------------------------------"
log_level -i "                Input Parameters"
log_level -i "------------------------------------------------------------------------"
log_level -i "IDENTITY_FILE       : $IDENTITY_FILE"
log_level -i "MASTER_IP           : $MASTER_IP"
log_level -i "OUTPUT_SUMMARYFILE  : $OUTPUT_SUMMARYFILE"
log_level -i "USER_NAME           : $USER_NAME"
log_level -i "------------------------------------------------------------------------"

if [[ -z "$IDENTITY_FILE" ]] || \
[[ -z "$MASTER_IP" ]] || \
[[ -z "$USER_NAME" ]] || \
[[ -z "$OUTPUT_SUMMARYFILE" ]]; then
    log_level -e "One of mandatory parameter is not passed correctly."
    print_usage
    exit 1
fi

###########################################################################################################
# Define all inner varaibles.
OUTPUT_FOLDER="$(dirname $OUTPUT_SUMMARYFILE)"
LOG_FILENAME="$OUTPUT_FOLDER/deploy.log"
touch $LOG_FILENAME

{
    HELM_INSTALL_FILENAME="install_helm.sh"
    INGRESS_CONFIG_FILENAME="ingress_config.yaml"
    INGRESS_METADATA_NAME="ingress-config"
    APPLICATION_NAME="ingress"
    TEST_FOLDER="/home/$USER_NAME/$APPLICATION_NAME"
    APPLICATION_FOLDER="applications/common"
    
    NAMESPACE_NAME="ingress-basic"
    CERT_FILENAME="azs-ingress-tls.crt"
    SECRETKEY_FILEANME="azs-ingress-tls.key"
    CN_NAME="test.azurestack.com"
    ORGANIZATION_NAME="azs-ingress-tls"
    HELM_APPLICATION_NAME="azure-samples/aks-helloworld"
    MAX_INGRESS_COUNT=2
    MAX_INGRESS_SERVICE_COUNT=8
    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Inner Variables"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "APPLICATION_FOLDER          : $APPLICATION_FOLDER"
    log_level -i "APPLICATION_NAME            : $APPLICATION_NAME"
    log_level -i "CERT_FILENAME               : $CERT_FILENAME"
    log_level -i "CN_NAME                     : $CN_NAME"
    log_level -i "HELM_INSTALL_FILENAME       : $HELM_INSTALL_FILENAME"
    log_level -i "HELM_APPLICATION_NAME       : $HELM_APPLICATION_NAME"
    log_level -i "INGRESS_CONFIG_FILENAME     : $INGRESS_CONFIG_FILENAME"
    log_level -i "GIT_BRANCH                  : $GIT_BRANCH"
    log_level -i "GIT_REPROSITORY             : $GIT_REPROSITORY"
    log_level -i "NAMESPACE_NAME              : $NAMESPACE_NAME"
    log_level -i "ORGANIZATION_NAME           : $ORGANIZATION_NAME"
    log_level -i "SECRETKEY_FILEANME          : $SECRETKEY_FILEANME"
    log_level -i "TEST_FOLDER                 : $TEST_FOLDER"
    log_level -i "------------------------------------------------------------------------"
    
    ###########################################################################################################
    download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
    $APPLICATION_FOLDER \
    $SCRIPT_FOLDER \
    $HELM_INSTALL_FILENAME
    
    if [[ $? != 0 ]]; then
        log_level -e "Download of file($HELM_INSTALL_FILENAME) failed."
        printf '{"result":"%s","error":"%s"}\n' "failed" "Download of file($HELM_INSTALL_FILENAME) was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
    "applications/webapp_$APPLICATION_NAME" \
    $SCRIPT_FOLDER \
    $INGRESS_CONFIG_FILENAME
    
    log_level -i "Create test folder($TEST_FOLDER)"
    ssh -q -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "mkdir -p $TEST_FOLDER"
    
    log_level -i "Copy file($HELM_INSTALL_FILENAME) to VM."
    scp -i $IDENTITY_FILE \
    $SCRIPT_FOLDER/$HELM_INSTALL_FILENAME \
    $USER_NAME@$MASTER_IP:$TEST_FOLDER/
    
    log_level -i "Copy file($COMMON_SCRIPT_FILENAME) to VM."
    scp -i $IDENTITY_FILE \
    $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME \
    $USER_NAME@$MASTER_IP:$TEST_FOLDER/
    
    # Install Helm chart
    install_helm_chart $IDENTITY_FILE \
    $USER_NAME \
    $MASTER_IP \
    $TEST_FOLDER \
    $HELM_INSTALL_FILENAME
    
    if [[ $? != 0 ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "Installing Helm was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    # Cleanup.
    ssh -q -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl delete namespace $NAMESPACE_NAME || true"
    sleep 5s
    log_level -i "Create namespace ($NAMESPACE_NAME)."
    ssh -q -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl create namespace $NAMESPACE_NAME"
    sleep 5s
    
    i=1
    while [ $i -le $MAX_INGRESS_COUNT ]; do
        ingressName=$APPLICATION_NAME-$i
        ingressFileName=$APPLICATION_NAME-$i.yaml
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "helm install stable/nginx-ingress --namespace $NAMESPACE_NAME --set controller.replicaCount=2 --name $ingressName || true"
        log_level -i "Copy $SCRIPT_FOLDER/$INGRESS_CONFIG_FILENAME to $OUTPUT_FOLDER/$ingressFileName."
        cp -f $SCRIPT_FOLDER/$INGRESS_CONFIG_FILENAME $OUTPUT_FOLDER/$ingressFileName
        
        loop=0
        while [ $loop -lt 20 ]; do
            IP_ADDRESS=$(ssh -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl get services -n $NAMESPACE_NAME -o json | jq --arg release $ingressName --arg component 'controller' '.items[] | select(.spec.selector.component == \$component) | select(.metadata.labels.release == \$release) | .status.loadBalancer.ingress[0].ip' | grep -oP '(\d{1,3}\.){1,3}\d{1,3}' || true")
            if [ -z "$IP_ADDRESS" ]; then
                log_level -i "External IP is not assigned. We we will retry after some time."
                sleep 30s
            else
                break
            fi
            let loop=loop+1
        done
        
        if [ -z "$IP_ADDRESS" ]; then
            log_level -e "External IP not found for $ingressName."
            printf '{"result":"%s","error":"%s"}\n' "failed" "External IP not found for $ingressName." > $OUTPUT_SUMMARYFILE
            exit 1
        fi
        
        certificateFileName=$ingressName-$CERT_FILENAME
        secretkeyFileName=$ingressName-$SECRETKEY_FILEANME
        cnName=$ingressName.$CN_NAME
        organizationName=$ingressName-$ORGANIZATION_NAME
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_FOLDER; source $COMMON_SCRIPT_FILENAME; create_cert $certificateFileName $secretkeyFileName $cnName $organizationName"
        log_level -i "Copy cert files locally to $OUTPUT_FOLDER"
        scp -r -i $IDENTITY_FILE $USER_NAME@$MASTER_IP:$TEST_FOLDER/$certificateFileName $OUTPUT_FOLDER/$certificateFileName
        scp -r -i $IDENTITY_FILE $USER_NAME@$MASTER_IP:$TEST_FOLDER/$secretkeyFileName $OUTPUT_FOLDER/$secretkeyFileName
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl create secret tls $organizationName --namespace $NAMESPACE_NAME --key $TEST_FOLDER/$secretkeyFileName --cert $TEST_FOLDER/$certificateFileName"
        
        rename_string_infile $OUTPUT_FOLDER/$ingressFileName $INGRESS_METADATA_NAME $ingressName
        rename_string_infile $OUTPUT_FOLDER/$ingressFileName $CN_NAME $cnName
        rename_string_infile $OUTPUT_FOLDER/$ingressFileName $ORGANIZATION_NAME $organizationName
        
        let i=i+1
    done
    
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "helm repo add azure-samples https://raw.githubusercontent.com/jadarsie/helm-charts/master/docs/"
    i=1
    ingressCount=0
    while [ $i -le $MAX_INGRESS_SERVICE_COUNT ]; do
        if [ $ingressCount -ge $MAX_INGRESS_COUNT ]; then
            ingressCount=1
        else
            let ingressCount=ingressCount+1
        fi
        
        ingressConfigFileName=$APPLICATION_NAME-$ingressCount.yaml
        randomName=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 3 | head -n 1)
        serviceName=$APPLICATION_NAME-$randomName$i
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_FOLDER; source $COMMON_SCRIPT_FILENAME; install_ingress_application $HELM_APPLICATION_NAME $NAMESPACE_NAME $serviceName $serviceName"
        echo "      - backend:
          serviceName: $serviceName
          servicePort: 80
        path: /$serviceName(/|$)(.*)" >> $OUTPUT_FOLDER/$ingressConfigFileName
        dos2unix $OUTPUT_FOLDER/$ingressConfigFileName
        sleep 15s
        let i=i+1
    done
    
    log_level -i "Copy ingress deployment files to VM."
    scp -i $IDENTITY_FILE \
    $OUTPUT_FOLDER/$APPLICATION_NAME-*.yaml \
    $USER_NAME@$MASTER_IP:$TEST_FOLDER/
    
    i=1
    while [ $i -le $MAX_INGRESS_COUNT ];do
        ingressConfigFileName=$APPLICATION_NAME-$i.yaml
        log_level -i "Deploy ingress configuration with file($ingressConfigFileName)"
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_FOLDER; kubectl apply -f $ingressConfigFileName"
        let i=i+1
    done
    
    deploymentNames=($(ssh -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl get services -n $NAMESPACE_NAME -o json | jq --arg type 'ClusterIP' '.items[] | select(.spec.type == \$type) | select(.spec.selector.component == null) | .metadata.name'"))
    deploymentCount="${#deploymentNames[@]}"
    log_level -i "App Deployment count is $deploymentCount"
    if [ $deploymentCount -eq $MAX_INGRESS_SERVICE_COUNT ]; then
        printf '{"result":"%s"}\n' "pass" > $OUTPUT_SUMMARYFILE
    else
        log_level -i "Get all objects from given namespace."
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl get all -n $NAMESPACE_NAME"
        log_level -i "Get ingress details."
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl get ingress -n $NAMESPACE_NAME -o json"
        printf '{"result":"%s","error":"%s"}\n' "failed" "Only $deploymentCount were successful." > $OUTPUT_SUMMARYFILE
    fi
    
    # Create result file, even if script ends with an error
    #trap final_changes EXIT
} 2>&1 | tee $LOG_FILENAME