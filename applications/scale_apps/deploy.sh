#!/bin/bash -e

rename_and_deploy()
{
    local deploymentFileName=$1;
    local kind=$2;
    local deploymentName=$3;
    local serviceName=$4;
    local appName=$5;
    local endEventName=$6;
    local numDeployments=$7;
    
    previousName=$deploymentName
    previousServiceName=$serviceName
    previousAppName=$appName
    
    if [[ -z "$numDeployments" ]]; then
        $numDeployments=5
    fi
	
    i=0
    while [ $i -lt $numDeployments ];do
        randomName=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 8 | head -n 1)
        currentName=$deploymentName$randomName
        currentServiceName=$serviceName-$randomName
        currentAppName=$appName-$randomName
        
        replicaCount=$(ssh -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; cat $TEST_DIRECTORY/$deploymentFileName | grep replicas | cut -d':' -f2 | xargs |  cut -d' ' -f1")
        
        tempDeploymentFileName=`echo "$deploymentFileName" | cut -d'.' -f1`
        newDeploymentFileName="${tempDeploymentFileName}_${randomName}.yaml"
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; cp $deploymentFileName $newDeploymentFileName"
        #replace the deployment,service and app name
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; source $COMMON_SCRIPT_FILENAME; rename_string_infile $TEST_DIRECTORY/$newDeploymentFileName $previousName $currentName"
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; source $COMMON_SCRIPT_FILENAME; rename_string_infile $TEST_DIRECTORY/$newDeploymentFileName $previousServiceName $currentServiceName"
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; source $COMMON_SCRIPT_FILENAME; rename_string_infile $TEST_DIRECTORY/$newDeploymentFileName $previousAppName $currentAppName"
        # deploy

        # This is the important line
        # This happens 50 times
        # deploy_application 
        # => kubectl apply -f applications/common/deploymentConfig/linux/nginx_*.yaml 
        # => check_Kubernetes_events "ScalingReplicaSet" or "SuccessfulAttachVolume"
        ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY; source $COMMON_SCRIPT_FILENAME; deploy_application $newDeploymentFileName $endEventName $currentName $kind $replicaCount"
		
		if [[ $i -lt 3 ]]; then
			sleep 300s
		fi

        log_level -i "Completed deploy iteration: $i"

        let i=i+1
    done
    return 0
}

FILE_NAME=$0

SCRIPT_DIRECTORY="$(dirname $FILE_NAME)"
GIT_REPROSITORY="${GIT_REPROSITORY:-msazurestackworkloads/kubetools}"
GIT_BRANCH="${GIT_BRANCH:-master}"
COMMON_SCRIPT_FILENAME="common.sh"

# Download common script file.
curl -o $SCRIPT_DIRECTORY/$COMMON_SCRIPT_FILENAME \
https://raw.githubusercontent.com/$GIT_REPROSITORY/$GIT_BRANCH/applications/common/$COMMON_SCRIPT_FILENAME
if [ ! -f $SCRIPT_DIRECTORY/$COMMON_SCRIPT_FILENAME ]; then
    log_level -e "File($COMMON_SCRIPT_FILENAME) failed to download."
    exit 1
fi

source $SCRIPT_DIRECTORY/$COMMON_SCRIPT_FILENAME
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
    log_level -e "One of the mandatory parameter is not passed correctly."
    print_usage
    exit 1
fi

###########################################################################################################
# Define all inner varaibles.
OUTPUT_DIRECTORY="$(dirname $OUTPUT_SUMMARYFILE)"
LOG_FILENAME="$OUTPUT_DIRECTORY/deploy.log"
touch $LOG_FILENAME

{
    # Details.
    APPLICATION_NAME="scale_apps"
    ATTACH_VOLUME_EVENT_NAME="SuccessfulAttachVolume"
    DEPLOYMENT_EVENT_NAME="ScalingReplicaSet"
    DEPLOYMENT_KIND="Deployment"
    DEPLOYMENT_NGINX_FILE="nginx_deploy.yaml"
    DEPLOYMENT_PVC_FILE="nginx_pvc_test.yaml"
    EXPECTED_RESULT_FILE="expectedresults.json"
    LINUX_SCRIPT_PATH="applications/common/deploymentConfig/linux"
    NGINX_APP_NAME="nginxtest"
    NGINX_NUM_DEPLOYMENTS=50
    NGINX_SERVICE_NAME="nginxservice"
    TEST_DIRECTORY="/home/$USER_NAME/$APPLICATION_NAME"
    POD_KIND="Pod"
    PVC_NUM_DEPLOYMENTS=10
    PVC_SERVICE_NAME="nginx-svc"
    PVC_APP_NAME="nginx-sts"
    NGINX_PVC_TEST=true
    NGINX_APP_TEST=true
    
    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Inner Variables"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "APPLICATION_NAME               : $APPLICATION_NAME"
    log_level -i "ATTACH_VOLUME_EVENT_NAME       : $ATTACH_VOLUME_EVENT_NAME"
    log_level -i "DEPLOYMENT_EVENT_NAME          : $DEPLOYMENT_EVENT_NAME"
    log_level -i "DEPLOYMENT_KIND                : $DEPLOYMENT_KIND"
    log_level -i "DEPLOYMENT_NGINX_FILE          : $DEPLOYMENT_NGINX_FILE"
    log_level -i "DEPLOYMENT_PVC_FILE            : $DEPLOYMENT_PVC_FILE"
    log_level -i "EXPECTED_RESULT_FILE           : $EXPECTED_RESULT_FILE"
    log_level -i "GIT_BRANCH                     : $GIT_BRANCH"
    log_level -i "GIT_REPROSITORY                : $GIT_REPROSITORY"
    log_level -i "LINUX_SCRIPT_PATH              : $LINUX_SCRIPT_PATH"
    log_level -i "NGINX_APP_NAME                 : $NGINX_APP_NAME"
    log_level -i "NGINX_APP_TEST                 : $NGINX_APP_TEST"
    log_level -i "NGINX_PVC_TEST                 : $NGINX_PVC_TEST"
    log_level -i "NGINX_NUM_DEPLOYMENTS          : $NGINX_NUM_DEPLOYMENTS"
    log_level -i "NGINX_SERVICE_NAME             : $NGINX_SERVICE_NAME"
    log_level -i "TEST_DIRECTORY                 : $TEST_DIRECTORY"
    log_level -i "POD_KIND                       : $POD_KIND"
    log_level -i "PVC_NUM_DEPLOYMENTS            : $PVC_NUM_DEPLOYMENTS "
    log_level -i "PVC_SERVICE_NAME               : $PVC_SERVICE_NAME"
    log_level -i "PVC_APP_NAME                   : $PVC_APP_NAME"
    log_level -i "------------------------------------------------------------------------"
    
    # ----------------------------------------------------------------------------------------
    # INSTALL PREREQUISITE
    
    apt_install_jq $OUTPUT_DIRECTORY
    if [[ $? != 0 ]]; then
        log_level -e "Install of jq was not successfull."
        printf '{"result":"%s","error":"%s"}\n' "failed" "Install of JQ was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
    "applications/$APPLICATION_NAME" \
    $SCRIPT_DIRECTORY \
    $EXPECTED_RESULT_FILE
    
    # ----------------------------------------------------------------------------------------
    # Copy all files inside master VM for execution.
    log_level -i "Create test directory($TEST_DIRECTORY)"
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "mkdir -p $TEST_DIRECTORY"
    
    log_level -i "Copy file($COMMON_SCRIPT_FILENAME) to VM."
    scp -i $IDENTITY_FILE \
    $SCRIPT_DIRECTORY/$COMMON_SCRIPT_FILENAME \
    $USER_NAME@$MASTER_IP:$TEST_DIRECTORY/
    
    if [[ "$NGINX_APP_TEST" == "true" ]]; then
        
        download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
        $LINUX_SCRIPT_PATH \
        $SCRIPT_DIRECTORY \
        $DEPLOYMENT_NGINX_FILE
        
        log_level -i "Copy file($DEPLOYMENT_NGINX_FILE) to VM."
        scp -i $IDENTITY_FILE \
        $SCRIPT_DIRECTORY/$DEPLOYMENT_NGINX_FILE \
        $USER_NAME@$MASTER_IP:$TEST_DIRECTORY/
        
        rename_and_deploy \
        $DEPLOYMENT_NGINX_FILE \
        $DEPLOYMENT_KIND \
        "nginx-scale" \
        $NGINX_SERVICE_NAME \
        $NGINX_APP_NAME \
        $DEPLOYMENT_EVENT_NAME \
        $NGINX_NUM_DEPLOYMENTS
    fi
    
    if [[ "$NGINX_PVC_TEST" == "true" ]]; then
        
        download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
        $LINUX_SCRIPT_PATH \
        $SCRIPT_DIRECTORY \
        $DEPLOYMENT_PVC_FILE
        
        log_level -i "Copy file($DEPLOYMENT_PVC_FILE) to VM."
        scp -i $IDENTITY_FILE \
        $SCRIPT_DIRECTORY/$DEPLOYMENT_PVC_FILE \
        $USER_NAME@$MASTER_IP:$TEST_DIRECTORY/
        
        rename_and_deploy \
        $DEPLOYMENT_PVC_FILE \
        $POD_KIND \
        "web" \
        $PVC_SERVICE_NAME \
        $PVC_APP_NAME \
        $ATTACH_VOLUME_EVENT_NAME \
        $PVC_NUM_DEPLOYMENTS
    fi
    
    log_level -i "Scale Operation setup done."
    printf '{"result":"%s"}\n' "pass" > $OUTPUT_SUMMARYFILE
} 2>&1 | tee $LOG_FILENAME